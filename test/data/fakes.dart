// Fakes for the data layer tests: a scriptable RemoteShell whose unix
// socket is a FakeDaemon, a controllable PTY and a static hosts repository.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agentd_app/src/core/contracts.dart';

import '../agentd/fake_daemon.dart';

/// A remote PTY driven by the test: [emit] prints, [written] records input,
/// [exit] ends it.
class TestPty implements PtySession {
  TestPty({this.command});
  final String? command;
  final _out = StreamController<Uint8List>();
  final _done = Completer<void>();
  final _exit = Completer<int?>();
  final List<String> written = [];
  (int, int)? size;

  void emit(String s) => _out.add(Uint8List.fromList(utf8.encode(s)));

  void exit([int code = 0]) {
    if (!_exit.isCompleted) _exit.complete(code);
    if (!_out.isClosed) _out.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  void add(List<int> data) => written.add(utf8.decode(data));

  @override
  void resize(int cols, int rows) => size = (cols, rows);

  @override
  Future<void> close() async => exit();

  @override
  Future<void> get done => _done.future;

  @override
  Future<int?> get exitCode => _exit.future;
}

/// RemoteShell: exec answered by rules (first substring/RegExp match),
/// `openUnixSocket` dials [daemon], `pty` hands out [TestPty]s.
class DataShell implements RemoteShell {
  DataShell({this.daemon, this.home = '/home/u'});

  final FakeDaemon? daemon;
  final String home;
  final List<(Pattern, ExecResult Function(String cmd, String? stdin))> _rules = [];
  final List<String> commands = [];
  final List<String?> stdins = [];
  final List<String> sockets = [];
  final List<TestPty> ptys = [];
  bool _closed = false;
  final Map<String, ({Uint8List data, int mode})> writes = {};
  bool failWrites = false;

  void on(Pattern p, ExecResult r) => _rules.add((p, (_, _) => r));
  void onRun(Pattern p, ExecResult Function(String cmd, String? stdin) f) => _rules.add((p, f));

  @override
  Future<ExecResult> exec(String command, {Duration timeout = const Duration(seconds: 30), String? stdin}) async {
    commands.add(command);
    stdins.add(stdin);
    for (final (p, f) in _rules) {
      if (p is RegExp ? p.hasMatch(command) : command.contains(p)) return f(command, stdin);
    }
    if (command == r'printf %s "$HOME"') return ExecResult(0, home, '');
    return const ExecResult(0, '', '');
  }

  @override
  Future<PtySession> pty({String? command, int cols = 80, int rows = 24, Map<String, String> env = const {}}) async {
    final p = TestPty(command: command)..size = (cols, rows);
    ptys.add(p);
    return p;
  }

  @override
  Future<ByteChannel> openUnixSocket(String path) {
    sockets.add(path);
    final d = daemon;
    if (d == null) return Future.error(StateError('no daemon'));
    return d.dial();
  }

  @override
  Future<void> writeFile(
    String path,
    Uint8List data, {
    int mode = 0x180,
  }) async {
    if (failWrites) throw StateError('disco lleno');
    writes[path] = (data: data, mode: mode);
  }

  @override
  Future<void> close() async => _closed = true;

  @override
  bool get isClosed => _closed;
}

/// Capabilities of a host with agentd (and optionally zellij / tmux).
HostCapabilities testCaps({bool agentd = true, bool zellij = false, bool tmux = false}) => HostCapabilities(
  os: 'Linux',
  arch: 'x86_64',
  systemdUser: true,
  runtimeDir: '/run/user/1000',
  agentdSocket: agentd ? '/run/user/1000/agentd/agentd.sock' : null,
  tools: {
    'agentd': ToolInfo('agentd', installed: agentd, version: '0.7.0', path: '/home/u/.local/bin/agentd'),
    'zellij': ToolInfo('zellij', installed: zellij),
    'tmux': ToolInfo('tmux', installed: tmux),
  },
);

/// HostsRepository over fixed statuses; [shell] returns [shells].
class StubHosts implements HostsRepository {
  StubHosts(List<HostStatus> hosts, this.shells) : _hosts = [...hosts];

  final List<HostStatus> _hosts;
  final Map<String, DataShell> shells;
  final _c = StreamController<List<HostStatus>>.broadcast();

  void set(List<HostStatus> hosts) {
    _hosts
      ..clear()
      ..addAll(hosts);
    _c.add(List.of(_hosts));
  }

  @override
  Stream<List<HostStatus>> watch() async* {
    yield List.of(_hosts);
    yield* _c.stream;
  }

  @override
  Future<RemoteShell> shell(String hostId) async => shells[hostId] ?? (throw StateError('no shell for $hostId'));

  @override
  Future<void> connect(String hostId) async {}

  @override
  Future<void> disconnect(String hostId) async {}

  @override
  Future<void> disconnectAll() async {}

  @override
  Future<void> reconnectAll() async {}

  @override
  Future<String> publicKey() async => 'ssh-ed25519 AAAA test';

  @override
  Future<void> remove(String hostId) async => removed.add(hostId);

  /// Hosts removed with [remove].
  final List<String> removed = [];

  @override
  Future<void> save(HostConfig config) async {}

  @override
  Future<HostConfig> enrollWithPassword(HostConfig config, String password) async => config;

  @override
  Future<HostConfig> pairRelay(String link, {required String deviceName, void Function(RelayPairPhase phase)? onPhase}) => throw UnimplementedError();

  /// Daemon connections of relay hosts.
  Future<ByteChannel> Function(String hostId)? relayDial;

  @override
  Future<ByteChannel> agentdChannel(String hostId) => relayDial?.call(hostId) ?? (throw StateError('no relay for $hostId'));
}

HostStatus onlineHost(String id, HostCapabilities caps) => HostStatus(HostConfig(id: id, name: id, host: '$id.local', user: 'u'), state: HostState.online, capabilities: caps);

/// Waits until [cond] holds (polling the event loop), or fails.
Future<void> eventually(bool Function() cond, {Duration timeout = const Duration(seconds: 5), String? reason}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException(reason ?? 'condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
