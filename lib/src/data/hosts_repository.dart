// HostsRepository: saved hosts, one pooled SSH connection per SSH host
// (trust on first use, detection after connect, password bootstrap) and one
// agentd-relay tunnel per relay host (pairing by invite link).

import 'dart:async';
import 'dart:io' show Platform, SocketException;

import 'package:dartssh2/dartssh2.dart' show SSHAuthError, SSHHandshakeError, SSHSocketError;

import '../agentd/agentd.dart' show AgentdClient;
import '../core/contracts.dart';
import '../relay/relay.dart';
import '../transport/transport.dart';
import 'authorized_keys.dart';
import 'host_store.dart';

/// Opens an authenticated shell for [config] ([password] only for the
/// password bootstrap). Replaceable in tests.
typedef HostConnect = Future<RemoteShell> Function(HostConfig config, {String? password});

/// Error of [SshHostsRepository.enrollWithPassword] (the key could not be
/// installed).
class EnrollError implements Exception {
  const EnrollError(this.message);
  final String message;

  @override
  String toString() => 'EnrollError: $message';
}

class SshHostsRepository implements HostsRepository {
  SshHostsRepository({
    required this._store,
    required this._keys,
    required this._hostKeys,
    required this._provision,
    required HostConnect connect,
    this.autoConnect = true,
    this.reconnectBackoff = const [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 15), Duration(seconds: 60)],
    RelayClient? relay,
    String? relayPlatform,
  }) : _connectFn = connect,
       _relay = relay ?? RelayClient(),
       relayPlatform = relayPlatform ?? (Platform.isIOS ? 'ios' : 'android') {
    _pool = ConnectionPool((c) => _connectFn(c));
  }

  /// The production wiring: dartssh2 connector with [prompts] as the TOFU
  /// callback.
  factory SshHostsRepository.ssh({
    required HostStore store,
    required KeyStore keys,
    required HostKeyStore hostKeys,
    required ProvisionService provision,
    required HostKeyPrompts prompts,
  }) {
    final connector = SshConnector(onNewHostKey: prompts.ask);
    return SshHostsRepository(
      store: store,
      keys: keys,
      hostKeys: hostKeys,
      provision: provision,
      connect: (c, {password}) => connector.connect(c, keyStore: keys, hostKeyStore: hostKeys, password: password),
    );
  }

  final HostStore _store;
  final KeyStore _keys;
  final HostKeyStore _hostKeys;
  final ProvisionService _provision;
  final HostConnect _connectFn;
  late final ConnectionPool _pool;
  final RelayClient _relay;

  /// Sent to relay hosts in the hello (`android` | `ios`).
  final String relayPlatform;

  /// One tunnel (dialer) per relay host.
  final Map<String, RelayDialer> _dialers = {};

  /// Connect every saved host when the list is first watched, and reconnect
  /// after a lost connection.
  final bool autoConnect;
  final List<Duration> reconnectBackoff;

  final List<String> _order = [];
  final Map<String, HostStatus> _hosts = {};
  final Map<String, Future<void>> _connecting = {};
  final Map<String, Timer> _retry = {};
  final Map<String, int> _attempts = {};

  /// Hosts the user disconnected: no automatic reconnect until [connect] or
  /// [reconnectAll].
  final Set<String> _off = {};

  /// Timeout of the liveness check of [reconnectAll].
  Duration probeTimeout = const Duration(seconds: 6);
  final _changes = StreamController<void>.broadcast();
  Future<void>? _loaded;
  bool _disposed = false;

  Future<void> _load() => _loaded ??= () async {
    for (final c in await _store.load()) {
      if (_hosts.containsKey(c.id)) continue;
      _order.add(c.id);
      _hosts[c.id] = HostStatus(c);
    }
    _notify();
    if (autoConnect) {
      for (final id in [..._order]) {
        unawaited(connect(id).catchError((Object _) {}));
      }
    }
  }();

  List<HostStatus> get _list => [for (final id in _order) ?_hosts[id]];

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _set(String id, HostStatus Function(HostStatus) f) {
    final h = _hosts[id];
    if (h == null) return;
    _hosts[id] = f(h);
    _notify();
  }

  Future<void> _persist() => _store.saveAll([for (final h in _list) h.config]);

  @override
  Stream<List<HostStatus>> watch() {
    late StreamController<List<HostStatus>> c;
    StreamSubscription<void>? sub;
    c = StreamController<List<HostStatus>>(
      onListen: () async {
        sub = _changes.stream.listen((_) => c.add(List.unmodifiable(_list)));
        await _load();
        if (!c.isClosed) c.add(List.unmodifiable(_list));
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  @override
  Future<void> save(HostConfig config) async {
    await _load();
    final old = _hosts[config.id];
    if (old == null) {
      _order.add(config.id);
      _hosts[config.id] = HostStatus(config);
    } else {
      _hosts[config.id] = HostStatus(config, state: old.state, capabilities: old.capabilities, error: old.error, sessionCount: old.sessionCount);
    }
    await _persist();
    _notify();
  }

  @override
  Future<void> remove(String hostId) async {
    await _load();
    _retry.remove(hostId)?.cancel();
    _order.remove(hostId);
    final removed = _hosts.remove(hostId);
    await _pool.drop(hostId);
    await _dialers.remove(hostId)?.close();
    await _hostKeys.remove(hostId);
    if (removed != null && removed.config.isRelay) await _keys.deleteSecret(relayKeySlot(removed.config.keyId ?? hostId));
    await _persist();
    _notify();
  }

  @override
  Future<void> connect(String hostId) async {
    await _load();
    _off.remove(hostId);
    final pending = _connecting[hostId];
    if (pending != null) return pending;
    final f = _connect(hostId, detect: true);
    _connecting[hostId] = f;
    try {
      await f;
    } finally {
      _connecting.remove(hostId);
    }
  }

  Future<void> _connect(String hostId, {required bool detect}) async {
    final h = _hosts[hostId];
    if (h == null) throw ArgumentError.value(hostId, 'hostId', 'unknown host');
    _retry.remove(hostId)?.cancel();
    _set(hostId, (h) => HostStatus(h.config, state: HostState.connecting, capabilities: h.capabilities, sessionCount: h.sessionCount));
    if (h.config.isRelay) {
      try {
        await _relayTunnel(hostId);
      } catch (e) {
        _set(hostId, (h) => HostStatus(h.config, state: HostState.error, capabilities: h.capabilities, error: describeConnectError(e)));
        rethrow;
      }
      _attempts.remove(hostId);
      return;
    }
    final RemoteShell shell;
    try {
      shell = await _pool.get(h.config);
    } catch (e) {
      _set(hostId, (h) => HostStatus(h.config, state: HostState.error, capabilities: h.capabilities, error: describeConnectError(e)));
      rethrow;
    }
    _attempts.remove(hostId);
    await _recordFingerprint(hostId, shell);
    _watchClose(hostId, shell);

    var caps = _hosts[hostId]?.capabilities;
    String? error;
    if (detect || caps == null) {
      try {
        caps = await _provision.detect(shell);
      } catch (_) {
        error = 'No se pudo detectar el host';
        caps ??= const HostCapabilities();
      }
    }
    _set(hostId, (h) => HostStatus(h.config, state: HostState.online, capabilities: caps, error: error, sessionCount: h.sessionCount));
  }

  /// Saves the fingerprint accepted on this connect into the config.
  Future<void> _recordFingerprint(String hostId, RemoteShell shell) async {
    final h = _hosts[hostId];
    if (h == null || h.config.hostKeyFingerprint != null) return;
    final fp = (shell is SshRemoteShell ? shell.hostKeyFingerprint : null) ?? await _hostKeys.get(hostId);
    if (fp == null) return;
    _hosts[hostId] = HostStatus(h.config.copyWith(hostKeyFingerprint: fp), state: h.state, capabilities: h.capabilities, error: h.error, sessionCount: h.sessionCount);
    await _persist();
  }

  void _watchClose(String hostId, RemoteShell shell) {
    if (shell is! SshRemoteShell) return;
    shell.done.then((_) {
      if (_disposed || !_hosts.containsKey(hostId) || _off.contains(hostId) || _pool.current(hostId) != null) return;
      _set(hostId, (h) => HostStatus(h.config, state: HostState.offline, capabilities: h.capabilities, error: 'Conexión perdida'));
      _scheduleReconnect(hostId);
    });
  }

  void _scheduleReconnect(String hostId) {
    if (!autoConnect || _disposed || reconnectBackoff.isEmpty || _off.contains(hostId)) return;
    final n = _attempts[hostId] = (_attempts[hostId] ?? 0) + 1;
    final d = reconnectBackoff[(n - 1).clamp(0, reconnectBackoff.length - 1)];
    _retry[hostId]?.cancel();
    _retry[hostId] = Timer(d, () {
      _retry.remove(hostId);
      if (_disposed || _pool.current(hostId) != null || _dialers[hostId]?.current != null) return;
      _connect(hostId, detect: false).catchError((Object _) => _scheduleReconnect(hostId));
    });
  }

  @override
  Future<void> disconnect(String hostId) async {
    await _load();
    if (!_hosts.containsKey(hostId)) return;
    _off.add(hostId);
    _retry.remove(hostId)?.cancel();
    _attempts.remove(hostId);
    await _pool.drop(hostId);
    await _dialers[hostId]?.close();
    _set(hostId, (h) => HostStatus(h.config, state: HostState.offline, capabilities: h.capabilities));
  }

  @override
  Future<void> disconnectAll() async {
    await _load();
    await Future.wait([for (final id in [..._order]) disconnect(id)]);
  }

  @override
  Future<void> reconnectAll() async {
    await _load();
    final work = <Future<void>>[];
    for (final id in [..._order]) {
      _off.remove(id);
      if (_connecting.containsKey(id)) continue;
      final tunnel = _dialers[id]?.current;
      if (tunnel != null) {
        work.add(_probeRelay(id, tunnel));
        continue;
      }
      final open = _pool.current(id);
      if (open != null) {
        work.add(_probe(id, open));
        continue;
      }
      _retry.remove(id)?.cancel();
      _attempts.remove(id);
      work.add(connect(id).catchError((Object _) {}));
    }
    await Future.wait(work);
  }

  /// Runs a no-op on [shell]; a connection that does not answer in
  /// [probeTimeout] (a socket the OS dropped while the app slept) is closed
  /// and opened again.
  Future<void> _probe(String hostId, RemoteShell shell) async {
    var alive = false;
    try {
      alive = (await shell.exec('true', timeout: probeTimeout).timeout(probeTimeout + const Duration(seconds: 1))).ok;
    } catch (_) {}
    if (alive || _disposed) return;
    await _pool.drop(hostId);
    _retry.remove(hostId)?.cancel();
    _attempts.remove(hostId);
    await connect(hostId).catchError((Object _) {});
  }

  @override
  Future<RemoteShell> shell(String hostId) async {
    await _load();
    final open = _pool.current(hostId);
    if (open != null) return open;
    final h = _hosts[hostId];
    if (h == null) throw ArgumentError.value(hostId, 'hostId', 'unknown host');
    if (h.config.isRelay) throw const NoShellOverRelay();
    final pending = _connecting[hostId];
    if (pending != null) {
      await pending;
    } else {
      final f = _connect(hostId, detect: false);
      _connecting[hostId] = f;
      try {
        await f;
      } finally {
        _connecting.remove(hostId);
      }
    }
    return _pool.get(_hosts[hostId]!.config);
  }

  // ---- Relay hosts ----

  @override
  Future<HostConfig> pairRelay(String link, {required String deviceName, void Function(RelayPairPhase phase)? onPhase}) async {
    await _load();
    final inv = RelayInvite.parse(link);
    // Pairing again with the same host replaces its saved entry.
    final existing = _list.where((h) => h.config.isRelay && h.config.relay?.route == inv.route).firstOrNull;
    final id = existing?.config.id ?? _freeId(_slug(inv.label.isEmpty ? 'relay' : inv.label));
    final dev = DhKey.generate();
    onPhase?.call(RelayPairPhase.connecting);
    final paired = await _relay.pair(inv, dev, name: deviceName, platform: relayPlatform, onPending: () => onPhase?.call(RelayPairPhase.waitingApproval));
    final keyId = 'relay-$id';
    await _keys.writeSecret(relayKeySlot(keyId), b64url(dev.private));
    final label = paired.host.isNotEmpty ? paired.host : inv.label;
    final config = HostConfig(
      id: id,
      name: existing?.config.name ?? (label.isEmpty ? 'relay' : label),
      host: Uri.parse(inv.relayUrl).host,
      port: 0,
      user: '',
      keyId: keyId,
      transport: HostTransport.relay,
      relay: RelayHostInfo(
        relayUrl: inv.relayUrl,
        route: inv.route,
        hostKey: b64url(inv.hostKey),
        deviceId: paired.device.id.isEmpty ? relayDeviceId(dev.public) : paired.device.id,
        scope: RelayScope.parse(paired.device.scope),
        sessions: paired.device.sessions,
        kind: paired.device.kind,
        label: label,
      ),
    );
    await _dialers.remove(id)?.close();
    await save(config);
    unawaited(connect(id).catchError((Object _) {}));
    return config;
  }

  String _freeId(String base) {
    var id = base.isEmpty ? 'relay' : base;
    for (var n = 2; _hosts.containsKey(id); n++) {
      id = '$base-$n';
    }
    return id;
  }

  static String _slug(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');

  @override
  Future<ByteChannel> agentdChannel(String hostId) async {
    await _load();
    var t = await _relayTunnel(hostId);
    try {
      return t.open();
    } on RelayError {
      // The tunnel died between the check and the open: one retry.
      t = await _relayTunnel(hostId);
      return t.open();
    }
  }

  Future<RelayDialer> _dialer(String hostId) async {
    final d = _dialers[hostId];
    if (d != null) return d;
    final c = _hosts[hostId]?.config;
    final info = c?.relay;
    if (c == null || info == null) throw ArgumentError.value(hostId, 'hostId', 'not a relay host');
    final secret = await _keys.readSecret(relayKeySlot(c.keyId ?? hostId));
    if (secret == null) throw const SshCredentialsError('no relay device key stored for this host');
    final target = RelayTarget(
      relayUrl: info.relayUrl,
      route: info.route,
      hostKey: unb64url(info.hostKey),
      device: DhKey.fromPrivate(unb64url(secret)),
      platform: relayPlatform,
    );
    return _dialers[hostId] ??= RelayDialer(_relay, target);
  }

  /// The live tunnel of a relay host, opened when needed. A new tunnel
  /// refreshes the device's scope from the welcome and marks the host online.
  Future<RelayTunnel> _relayTunnel(String hostId) async {
    final d = await _dialer(hostId);
    final had = d.current;
    final t = await d.tunnel();
    if (!identical(had, t)) await _onTunnel(hostId, d, t);
    return t;
  }

  Future<void> _onTunnel(String hostId, RelayDialer d, RelayTunnel t) async {
    final h = _hosts[hostId];
    final info = h?.config.relay;
    if (h == null || info == null) return;
    final dev = t.welcome.device;
    final updated = info.copyWith(
      scope: dev == null ? null : RelayScope.parse(dev.scope),
      sessions: dev?.sessions,
      kind: dev == null || dev.kind.isEmpty ? null : dev.kind,
      label: t.welcome.host.isEmpty ? null : t.welcome.host,
    );
    final config = updated.sameAs(info) ? h.config : h.config.copyWith(relay: updated);
    _hosts[hostId] = HostStatus(config, state: HostState.online, capabilities: relayCapabilities, sessionCount: h.sessionCount);
    _attempts.remove(hostId);
    _notify();
    if (!identical(config, h.config)) await _persist();
    unawaited(
      t.done.then((_) {
        if (_disposed || !_hosts.containsKey(hostId) || _off.contains(hostId) || d.current != null || !identical(_dialers[hostId], d)) return;
        _set(hostId, (h) => HostStatus(h.config, state: HostState.offline, capabilities: h.capabilities, error: 'Conexión perdida'));
        _scheduleReconnect(hostId);
      }),
    );
  }

  /// A ping through the live tunnel; a tunnel that does not answer within
  /// [probeTimeout] (dropped while the app slept) is closed and reopened.
  Future<void> _probeRelay(String hostId, RelayTunnel t) async {
    var alive = false;
    try {
      await AgentdClient(() async => t.open(), timeout: probeTimeout).ping();
      alive = true;
    } catch (_) {}
    if (alive || _disposed) return;
    await t.close();
    _retry.remove(hostId)?.cancel();
    _attempts.remove(hostId);
    await connect(hostId).catchError((Object _) {});
  }

  @override
  Future<String> publicKey() => _keys.ensureGeneratedKey();

  @override
  Future<HostConfig> enrollWithPassword(HostConfig config, String password) async {
    if (password.isEmpty) throw ArgumentError('empty password');
    await _load();
    final pub = await _keys.ensureGeneratedKey();
    final pwConfig = HostConfig(id: config.id, name: config.name, host: config.host, port: config.port, user: config.user, auth: AuthKind.password, hostKeyFingerprint: config.hostKeyFingerprint);
    final RemoteShell shell;
    try {
      shell = await _connectFn(pwConfig, password: password);
    } catch (e) {
      throw EnrollError(describeConnectError(e));
    }
    String? fp;
    try {
      final r = await shell.exec(installAuthorizedKeyScript, stdin: '$pub\n');
      if (!r.ok) {
        throw EnrollError('no se pudo instalar la clave (código ${r.exitCode ?? '?'})${r.stderr.trim().isEmpty ? '' : ': ${r.stderr.trim()}'}');
      }
      fp = (shell is SshRemoteShell ? shell.hostKeyFingerprint : null) ?? await _hostKeys.get(config.id);
    } finally {
      try {
        await shell.close();
      } catch (_) {}
    }
    final saved = HostConfig(
      id: config.id,
      name: config.name,
      host: config.host,
      port: config.port,
      user: config.user,
      auth: AuthKind.generatedKey,
      hostKeyFingerprint: fp ?? config.hostKeyFingerprint,
    );
    await save(saved);
    return saved;
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final t in _retry.values) {
      t.cancel();
    }
    _retry.clear();
    await _pool.dispose();
    for (final d in _dialers.values) {
      await d.close();
    }
    _dialers.clear();
    await _changes.close();
  }
}

/// User-facing (Spanish) text for a connect failure. Never includes
/// credentials.
String describeConnectError(Object e) {
  if (e is RelayError) return describeRelayError(e);
  if (e is InviteFormatError) return 'Enlace de invitación no válido';
  if (e is NoShellOverRelay) return 'Un host por relay no tiene shell (solo sesiones de agentd)';
  if (e is HostKeyMismatch) return 'La huella del host cambió (${e.actual}): posible suplantación. Borra la huella guardada solo si sabes por qué cambió.';
  if (e is HostKeyRejected) return 'Huella del host no aceptada';
  if (e is SshCredentialsError) return 'Sin credenciales válidas para este host';
  if (e is SSHAuthError) return 'El host rechazó la autenticación';
  if (e is SSHHandshakeError) return 'Fallo en el saludo SSH';
  if (e is TimeoutException) return 'Tiempo de espera agotado';
  if (e is SocketException || e is SSHSocketError) return 'No se pudo conectar con el host';
  if (e is EnrollError) return e.message;
  return 'Error de conexión';
}

/// Secure-store slot of a relay device key (X25519 private, base64url).
String relayKeySlot(String keyId) => 'agentd.relay.key.$keyId';

/// What a relay host reports when it is online: agentd only (no shell, so
/// no zellij/tmux, provisioning or folder browsing).
const relayCapabilities = HostCapabilities(agentdSocket: 'relay', tools: {'agentd': ToolInfo('agentd', installed: true)});

/// [HostsRepository.shell] on a relay host.
class NoShellOverRelay implements Exception {
  const NoShellOverRelay();

  @override
  String toString() => 'NoShellOverRelay: relay hosts have no shell';
}

/// User-facing (Spanish) text for a relay failure.
String describeRelayError(RelayError e) => switch (e.failure) {
  RelayFailure.hostOffline => 'El host no está conectado al relay (¿agentd parado o [relay] desactivado?)',
  RelayFailure.hostNoAnswer => 'El host no respondió a tiempo',
  RelayFailure.rateLimited => 'Demasiados intentos; prueba en un minuto',
  RelayFailure.tooManyTunnels => 'Demasiadas conexiones a este host',
  RelayFailure.unreachable => 'No se pudo conectar con el relay',
  RelayFailure.handshake => 'Fallo en el saludo cifrado (invitación usada o caducada, o la clave del host cambió)',
  RelayFailure.refused => e.code == 'forbidden' ? 'El host no reconoce este dispositivo (¿revocado?)' : 'El host rechazó la conexión: ${e.message}',
  RelayFailure.denied => 'El host rechazó el emparejamiento',
  RelayFailure.protocol => 'Conexión con el relay perdida',
};
