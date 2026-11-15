// HostsRepository over SSH: saved hosts, one pooled connection per host,
// trust on first use, detection after connect, password bootstrap.

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:dartssh2/dartssh2.dart' show SSHAuthError, SSHHandshakeError, SSHSocketError;

import '../core/contracts.dart';
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
  }) : _connectFn = connect {
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

  /// Connect every saved host when the list is first watched, and reconnect
  /// after a lost connection.
  final bool autoConnect;
  final List<Duration> reconnectBackoff;

  final List<String> _order = [];
  final Map<String, HostStatus> _hosts = {};
  final Map<String, Future<void>> _connecting = {};
  final Map<String, Timer> _retry = {};
  final Map<String, int> _attempts = {};
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
    _hosts.remove(hostId);
    await _pool.drop(hostId);
    await _hostKeys.remove(hostId);
    await _persist();
    _notify();
  }

  @override
  Future<void> connect(String hostId) async {
    await _load();
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
      if (_disposed || !_hosts.containsKey(hostId) || _pool.current(hostId) != null) return;
      _set(hostId, (h) => HostStatus(h.config, state: HostState.offline, capabilities: h.capabilities, error: 'Conexión perdida'));
      _scheduleReconnect(hostId);
    });
  }

  void _scheduleReconnect(String hostId) {
    if (!autoConnect || _disposed || reconnectBackoff.isEmpty) return;
    final n = _attempts[hostId] = (_attempts[hostId] ?? 0) + 1;
    final d = reconnectBackoff[(n - 1).clamp(0, reconnectBackoff.length - 1)];
    _retry[hostId]?.cancel();
    _retry[hostId] = Timer(d, () {
      _retry.remove(hostId);
      if (_disposed || _pool.current(hostId) != null) return;
      _connect(hostId, detect: false).catchError((Object _) => _scheduleReconnect(hostId));
    });
  }

  @override
  Future<RemoteShell> shell(String hostId) async {
    await _load();
    final open = _pool.current(hostId);
    if (open != null) return open;
    final h = _hosts[hostId];
    if (h == null) throw ArgumentError.value(hostId, 'hostId', 'unknown host');
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
    await _changes.close();
  }
}

/// User-facing (Spanish) text for a connect failure. Never includes
/// credentials.
String describeConnectError(Object e) {
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
