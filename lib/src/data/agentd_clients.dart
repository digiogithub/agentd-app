// One AgentdClient per host, dialing the daemon socket over the host's SSH
// connection (direct-streamlocal), or a stream of its agentd-relay tunnel.

import 'dart:async';

import '../agentd/agentd.dart';
import '../core/contracts.dart';

/// Builds the dial function for the daemon socket [socket] of [hostId].
typedef AgentdDialFactory = AgentdDial Function(String hostId, String socket);

/// The agentd socket of a host, when it is online and has agentd.
String? agentdSocketOf(HostStatus h) {
  final caps = h.capabilities;
  if (h.state != HostState.online || caps == null) return null;
  final socket = caps.agentdSocket;
  if (socket == null || socket.isEmpty || !caps.has('agentd')) return null;
  return socket;
}

class AgentdClients {
  AgentdClients(this._hosts, {AgentdDialFactory? dial, this.autostartEvery = const Duration(seconds: 30)}) {
    _dial = dial ?? _sshDial;
  }

  final HostsRepository _hosts;
  late final AgentdDialFactory _dial;

  /// Minimum interval between two attempts to start a stopped daemon.
  final Duration autostartEvery;

  final Map<String, HostStatus> _latest = {};
  final Map<String, (String, AgentdClient)> _clients = {};
  final Map<String, DateTime> _autostarted = {};
  final Completer<void> _first = Completer<void>();
  StreamSubscription<List<HostStatus>>? _sub;

  void _start() {
    _sub ??= _hosts.watch().listen((list) {
      _latest
        ..clear()
        ..addEntries(list.map((h) => MapEntry(h.config.id, h)));
      if (!_first.isCompleted) _first.complete();
    });
  }

  /// Dials the socket over the host's shell. When the socket is missing (the
  /// daemon is not running) the agentd CLI is run once (it autostarts the
  /// daemon) and the dial retried.
  AgentdDial _sshDial(String hostId, String socket) => () async {
    final shell = await _hosts.shell(hostId);
    try {
      return await shell.openUnixSocket(socket);
    } catch (_) {
      final last = _autostarted[hostId];
      final now = DateTime.now();
      if (last != null && now.difference(last) < autostartEvery) rethrow;
      _autostarted[hostId] = now;
      final bin = _latest[hostId]?.capabilities?.tools['agentd']?.path ?? 'agentd';
      await shell.exec('${_q(bin)} ls >/dev/null 2>&1', timeout: const Duration(seconds: 15));
      return shell.openUnixSocket(socket);
    }
  };

  /// The client for a host in [status] (null without agentd).
  AgentdClient? forStatus(HostStatus status) {
    final socket = agentdSocketOf(status);
    final id = status.config.id;
    if (socket == null) return null;
    final cached = _clients[id];
    if (cached != null && cached.$1 == socket) return cached.$2;
    final c = AgentdClient(status.config.isRelay ? () => _hosts.agentdChannel(id) : _dial(id, socket));
    _clients[id] = (socket, c);
    return c;
  }

  /// The client for [hostId], once the host list is known (null when the
  /// host is offline or has no agentd).
  Future<AgentdClient?> forHost(String hostId) async {
    _start();
    await _first.future;
    final h = _latest[hostId];
    return h == null ? null : forStatus(h);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
  }
}

String _q(String s) => RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(s) ? s : "'${s.replaceAll("'", r"'\''")}'";
