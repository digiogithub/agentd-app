// SessionsRepository over every connected host: agentd sessions from the
// daemon event bus (views fetched on demand), zellij / tmux sessions polled
// while the list is watched, and SSH login shells started by the app.

import 'dart:async';
import 'dart:typed_data';

import '../agentd/agentd.dart';
import '../core/contracts.dart';
import '../mux/mux.dart';
import '../mux/quote.dart';
import 'agentd_clients.dart';
import 'list_dir.dart';
import 'shell_session.dart';

/// Multiplexer adapters for a host (by its capabilities).
typedef MuxFactory = List<MuxAdapter> Function(RemoteShell shell, HostStatus host);

List<MuxAdapter> defaultMuxAdapters(RemoteShell shell, HostStatus h) => [
  if (h.capabilities?.has('zellij') ?? false) ZellijAdapter(shell, hostId: h.config.id),
  if (h.capabilities?.has('tmux') ?? false) TmuxAdapter(shell, hostId: h.config.id),
];

/// Last non-blank transcript line of a view (the inbox preview).
String? previewOf(AgentdView v) {
  for (final l in v.lines.reversed) {
    if (l.role != 'transcript') continue;
    final t = l.text.trim();
    if (t.isNotEmpty) return t.length <= 160 ? t : '${t.substring(0, 159)}…';
  }
  return null;
}

AgentSession _copy(
  AgentSession s, {
  AgentStatus? status,
  bool? attention,
  String? preview,
  int? turn,
  PendingInteraction? pending,
  bool clearPending = false,
  String? harness,
  String? project,
}) => AgentSession(
  hostId: s.hostId,
  source: s.source,
  name: s.name,
  harness: harness ?? s.harness,
  project: project ?? s.project,
  status: status ?? s.status,
  attention: attention ?? s.attention,
  preview: preview ?? s.preview,
  cwd: s.cwd,
  turn: turn ?? s.turn,
  updatedAt: DateTime.now(),
  pending: clearPending ? null : (pending ?? s.pending),
  detail: s.detail,
);

class LiveSessionsRepository implements SessionsRepository {
  LiveSessionsRepository({
    required this._hosts,
    required this._clients,
    MuxFactory? mux,
    this.muxPoll = const Duration(seconds: 5),
    this.refreshDebounce = const Duration(milliseconds: 150),
    this.viewLines = 300,
    this.promptRetry = const Duration(seconds: 2),
    this.promptWait = const Duration(seconds: 90),
    this.terminateWait = const Duration(seconds: 5),
    this.terminatePoll = const Duration(milliseconds: 250),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _muxFactory = mux ?? defaultMuxAdapters;

  final DateTime Function() _now;

  final HostsRepository _hosts;
  final AgentdClients _clients;
  final MuxFactory _muxFactory;

  /// zellij / tmux listing interval while [watch] has listeners.
  final Duration muxPoll;

  /// Coalescing delay of view refreshes triggered by events.
  final Duration refreshDebounce;

  /// Transcript lines fetched for an open session.
  final int viewLines;

  /// First prompt of a launched agentd session: retried every [promptRetry]
  /// (while the agent starts) for at most [promptWait].
  final Duration promptRetry;
  final Duration promptWait;

  /// [terminate] of an agentd session: how long to wait for the killed
  /// process to be reported exited, polling `ls` every [terminatePoll].
  final Duration terminateWait;
  final Duration terminatePoll;

  final Map<String, HostStatus> _hostStatus = {};
  final Map<String, _AgentdHost> _agentd = {};
  final Map<String, List<AgentSession>> _mux = {};
  final Map<String, Timer> _muxTimers = {};
  final Set<String> _muxPolling = {};
  final Map<String, ShellSession> _shells = {};
  final Map<String, _Feed> _feeds = {};
  final Map<String, String> _homes = {};
  final Map<String, (DateTime, Map<String, String>)> _aliases = {};
  final _changes = StreamController<void>.broadcast();
  StreamSubscription<List<HostStatus>>? _hostsSub;
  int _watchers = 0;
  int _viewers = 0;

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ---- Lifecycle ----

  void _ensureStarted() {
    _hostsSub ??= _hosts.watch().listen(_onHosts);
  }

  void _maybeStop() {
    if (_watchers > 0 || _viewers > 0) {
      if (_watchers == 0) _stopMuxTimers();
      return;
    }
    _hostsSub?.cancel();
    _hostsSub = null;
    for (final h in _agentd.values) {
      h.dispose();
    }
    _agentd.clear();
    _stopMuxTimers();
    _mux.clear();
  }

  void _stopMuxTimers() {
    for (final t in _muxTimers.values) {
      t.cancel();
    }
    _muxTimers.clear();
  }

  void _onHosts(List<HostStatus> list) {
    final ids = {for (final h in list) h.config.id};
    for (final gone in _hostStatus.keys.where((id) => !ids.contains(id)).toList()) {
      _dropHost(gone, closeShells: true);
      _hostStatus.remove(gone);
    }
    for (final h in list) {
      final id = h.config.id;
      _hostStatus[id] = h;
      if (h.state != HostState.online) {
        _dropHost(id, closeShells: false);
        continue;
      }
      final client = _clients.forStatus(h);
      final cur = _agentd[id];
      if (client == null) {
        cur?.dispose();
        _agentd.remove(id);
      } else if (cur == null || !identical(cur.client, client)) {
        cur?.dispose();
        _agentd[id] = _AgentdHost(this, id, client)..start();
        _refreshFeedsOf(id);
      }
      _syncMux(h);
    }
    _notify();
  }

  void _dropHost(String id, {required bool closeShells}) {
    _agentd.remove(id)?.dispose();
    _muxTimers.remove(id)?.cancel();
    _mux.remove(id);
    if (closeShells) {
      for (final k in _shells.keys.where((k) => k.startsWith('$id/')).toList()) {
        unawaited(_shells.remove(k)!.close());
      }
    }
  }

  bool _hasMux(HostStatus h) => (h.capabilities?.has('zellij') ?? false) || (h.capabilities?.has('tmux') ?? false);

  void _syncMux(HostStatus h) {
    final id = h.config.id;
    if (!_hasMux(h)) {
      _muxTimers.remove(id)?.cancel();
      _mux.remove(id);
      return;
    }
    if (_watchers == 0 || _muxTimers.containsKey(id)) return;
    _muxTimers[id] = Timer.periodic(muxPoll, (_) => _pollMux(id));
    unawaited(_pollMux(id));
  }

  Future<void> _pollMux(String id) async {
    final h = _hostStatus[id];
    if (h == null || h.state != HostState.online || !_muxPolling.add(id)) return;
    try {
      final shell = await _hosts.shell(id);
      final found = <AgentSession>[];
      for (final a in _muxFactory(shell, h)) {
        try {
          found.addAll(await a.list());
        } catch (_) {
          // Not installed / no server: no sessions from it.
        }
      }
      if (_hostStatus[id]?.state != HostState.online) return;
      final old = _mux[id] ?? const [];
      _mux[id] = found;
      if (!_sameList(old, found)) _notify();
    } catch (_) {
      // Connection trouble: keep the last list, the hosts repo reports it.
    } finally {
      _muxPolling.remove(id);
    }
  }

  static bool _sameList(List<AgentSession> a, List<AgentSession> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key || a[i].status != b[i].status || a[i].detail != b[i].detail || a[i].harness != b[i].harness) return false;
    }
    return true;
  }

  List<AgentSession> _all() {
    final res = <AgentSession>[];
    final ids = [..._hostStatus.keys, ..._shells.values.map((s) => s.session.hostId).where((id) => !_hostStatus.containsKey(id))];
    for (final id in {...ids}) {
      res.addAll(_agentd[id]?.sessions.values ?? const <AgentSession>[]);
      res.addAll(_mux[id] ?? const <AgentSession>[]);
      res.addAll(_shells.values.where((s) => s.session.hostId == id).map((s) => s.session));
    }
    return List.unmodifiable(res);
  }

  AgentSession? _find(String key) {
    for (final s in _all()) {
      if (s.key == key) return s;
    }
    return null;
  }

  // ---- SessionsRepository ----

  @override
  Stream<List<AgentSession>> watch() {
    late StreamController<List<AgentSession>> c;
    StreamSubscription<void>? sub;
    c = StreamController<List<AgentSession>>(
      onListen: () {
        _watchers++;
        _ensureStarted();
        for (final h in _hostStatus.values) {
          if (h.state == HostState.online) _syncMux(h);
        }
        c.add(_all());
        sub = _changes.stream.listen((_) => c.add(_all()));
      },
      onCancel: () {
        sub?.cancel();
        _watchers--;
        _maybeStop();
      },
    );
    return c.stream;
  }

  @override
  Stream<SessionView> view(AgentSession session) {
    if (session.source != SessionSource.agentd) {
      // Terminal-only sessions: the view is just the live session.
      late StreamController<SessionView> c;
      StreamSubscription<void>? sub;
      c = StreamController<SessionView>(
        onListen: () {
          _viewers++;
          _ensureStarted();
          c.add(SessionView(session: _find(session.key) ?? session));
          sub = _changes.stream.listen((_) {
            final s = _find(session.key);
            if (s != null) c.add(SessionView(session: s));
          });
        },
        onCancel: () {
          sub?.cancel();
          _viewers--;
          _maybeStop();
        },
      );
      return c.stream;
    }
    late StreamController<SessionView> c;
    c = StreamController<SessionView>(
      onListen: () {
        _viewers++;
        _ensureStarted();
        final f = _feeds.putIfAbsent(session.key, () => _Feed(this, session));
        f.listeners.add(c);
        final last = f.last;
        if (last != null) c.add(last);
        f.refresh(ack: f.listeners.length == 1);
      },
      onCancel: () {
        final f = _feeds[session.key];
        f?.listeners.remove(c);
        if (f != null && f.listeners.isEmpty) _feeds.remove(session.key);
        _viewers--;
        _maybeStop();
      },
    );
    return c.stream;
  }

  void _refreshFeedsOf(String hostId) {
    for (final f in _feeds.values.where((f) => f.base.hostId == hostId)) {
      f.refresh();
    }
  }

  /// Refreshes the open view of a session, if any. Returns whether one was open.
  bool _refreshFeed(String key, {bool now = false}) {
    final f = _feeds[key];
    if (f == null) return false;
    f.refresh(debounce: !now);
    return true;
  }

  Future<AgentdClient> _clientOf(AgentSession s) async {
    if (s.source != SessionSource.agentd) throw UnsupportedError('${s.source.name} sessions have no agentd actions');
    final c = await _clients.forHost(s.hostId);
    if (c == null) throw StateError('host ${s.hostId} has no reachable agentd');
    return c;
  }

  @override
  Future<void> prompt(AgentSession s, String text) async {
    final c = await _clientOf(s);
    // Most agents take a message in the middle of a turn: do not wait for idle.
    await c.prompt(s.name, text, force: s.status == AgentStatus.working);
    _refreshFeed(s.key, now: true);
  }

  final Map<String, String> _uploadBases = {};
  final Set<String> _uploadDirs = {};
  int _uploadSeq = 0;

  @override
  Future<String> uploadImage(
    AgentSession s,
    Uint8List bytes, {
    required String extension,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9]{1,5}$').hasMatch(extension)) {
      throw ArgumentError.value(extension, 'extension');
    }
    final ext = extension.toLowerCase();
    final shell = await _hosts.shell(s.hostId);
    var base = _uploadBases[s.hostId];
    if (base == null) {
      var dir = '';
      try {
        final r = await shell.exec(
          r'printf %s "${XDG_CACHE_HOME:-$HOME/.cache}"',
        );
        if (r.ok) dir = r.stdout.trim();
      } catch (_) {}
      if (!dir.startsWith('/')) dir = '${await _home(s.hostId)}/.cache';
      base = _uploadBases[s.hostId] = '$dir/agentd-app/uploads';
    }
    final dir = '$base/${uploadDirName(s.name)}';
    if (_uploadDirs.add('${s.hostId}|$dir')) {
      try {
        final r = await shell.exec(
          'umask 077; mkdir -p ${posixQuote(dir)} && chmod 700 ${posixQuote(dir)}',
        );
        if (!r.ok) throw StateError(r.stderr.trim());
      } catch (_) {
        _uploadDirs.remove('${s.hostId}|$dir');
        rethrow;
      }
    }
    final path = '$dir/${uploadFileName(_now(), ++_uploadSeq, ext)}';
    await shell.writeFile(path, bytes, mode: 0x180);
    return path;
  }

  @override
  Future<void> choose(AgentSession s, SessionOption option, {required int revision, required String epoch}) async {
    final c = await _clientOf(s);
    try {
      await c.choose(s.name, option.id, label: option.label, revision: revision, epoch: epoch);
    } on AgentdError catch (e) {
      final v = AgentdClient.conflictView(e);
      if (v != null) _feeds[s.key]?.apply(v);
      rethrow;
    } finally {
      _refreshFeed(s.key, now: true);
    }
  }

  @override
  Future<void> keys(AgentSession s, List<String> keys) async {
    final c = await _clientOf(s);
    await c.keys(s.name, keys);
    _refreshFeed(s.key);
  }

  @override
  Future<void> interrupt(AgentSession s) async {
    final c = await _clientOf(s);
    await c.interrupt(s.name);
    _refreshFeed(s.key, now: true);
  }

  @override
  Future<PtySession> terminal(AgentSession s, {int cols = 80, int rows = 24, bool observe = false}) async {
    switch (s.source) {
      case SessionSource.agentd:
        final c = await _clientOf(s);
        // passive: the phone does not take the agent's PTY size at attach.
        return c.attach(s.name, cols: cols, rows: rows, observe: observe, passive: true, history: 2000);
      case SessionSource.zellij:
      case SessionSource.tmux:
        final h = _hostStatus[s.hostId];
        if (h == null) throw StateError('unknown host ${s.hostId}');
        final shell = await _hosts.shell(s.hostId);
        final a = _muxFactory(shell, h).where((a) => a.source == s.source).firstOrNull;
        if (a == null) throw StateError('${s.source.name} is not available on ${s.hostId}');
        return a.attach(s.name, cols: cols, rows: rows);
      case SessionSource.shell:
        final sh = _shells[s.key];
        if (sh == null || sh.isDone) throw StateError('the shell ${s.name} has ended');
        return sh.attach(cols: cols, rows: rows);
    }
  }

  @override
  Future<List<String>> projects(String hostId) async => (await _aliasDirs(hostId)).keys.toList();

  /// agentd aliases of a host (name → dir), cached 30 s. Empty without agentd.
  Future<Map<String, String>> _aliasDirs(String hostId) async {
    final cached = _aliases[hostId];
    if (cached != null && DateTime.now().difference(cached.$1) < const Duration(seconds: 30)) return cached.$2;
    final c = await _clients.forHost(hostId);
    if (c == null) return const {};
    try {
      final info = await c.info();
      final m = {for (final a in info.aliases) a.name: a.dir};
      _aliases[hostId] = (DateTime.now(), m);
      return m;
    } catch (_) {
      return cached?.$2 ?? const {};
    }
  }

  Future<String> _home(String hostId) async {
    final h = _homes[hostId];
    if (h != null) return h;
    final r = await (await _hosts.shell(hostId)).exec(r'printf %s "$HOME"');
    final home = r.stdout.trim();
    if (!r.ok || !home.startsWith('/')) throw StateError('cannot read \$HOME on $hostId');
    return _homes[hostId] = home;
  }

  /// Directory of [project]: an alias's dir, an absolute or `~` path as
  /// given, else a path relative to the home directory.
  Future<String> _dir(String hostId, String project) async {
    final p = project.trim();
    final alias = (await _aliasDirs(hostId))[p];
    if (alias != null) return alias;
    if (p.startsWith('/') || p == '~' || p.startsWith('~/')) return p;
    return '~/$p';
  }

  Future<String> _absDir(String hostId, String dir) async {
    if (dir == '~' || dir.startsWith('~/')) return '${await _home(hostId)}${dir.substring(1)}';
    return dir;
  }

  static String _label(String project) {
    var p = project.trim();
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    final base = p.split('/').last;
    final s = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-').replaceAll(RegExp(r'^[.-]+'), '');
    return s.isEmpty ? 'home' : s;
  }

  static const _loginShell = r'exec "${SHELL:-sh}" -l';

  /// Terminal only (no agent): `shell` (`bash` kept for old callers).
  static bool _isShell(String harness) => harness.isEmpty || harness == kShellHarness || harness == 'bash';

  @override
  Future<AgentSession> launch({required String hostId, required SessionSource where, required String project, required String harness, String? firstPrompt}) async {
    _ensureStarted();
    final h = _hostStatus[hostId];
    switch (where) {
      case SessionSource.agentd:
        final c = await _clients.forHost(hostId);
        if (c == null) throw StateError('host $hostId has no reachable agentd');
        final aliases = await _aliasDirs(hostId);
        final p = project.trim();
        final AgentdSessionInfo info;
        if (h?.config.isRelay ?? false) {
          // Over the relay the daemon starts harnesses from its profiles
          // only (no cmd, so no plain terminal) and there is no shell to
          // expand `~`: an alias or an absolute directory.
          if (_isShell(harness)) throw UnsupportedError('a relay host cannot open a plain terminal');
          if (!aliases.containsKey(p) && !p.startsWith('/')) throw ArgumentError.value(project, 'project', 'relay hosts need an alias or an absolute path');
          info = await c.run(target: p, harness: harness);
        } else if (_isShell(harness)) {
          final target = aliases.containsKey(p) ? p : await _absDir(hostId, await _dir(hostId, p));
          // A login shell: the `shell` harness with an explicit command; its
          // profile is `default` unless the daemon has one called `shell`.
          var profile = 'default';
          try {
            if ((await c.info()).profiles.any((p) => p.name == kShellHarness)) profile = kShellHarness;
          } catch (_) {}
          final home = await _home(hostId);
          Future<AgentdSessionInfo> run([String? name]) =>
              c.run(target: target, harness: kShellHarness, name: name, cmd: const ['sh', '-c', _loginShell], profile: profile, cwd: home);
          // Several terminals may share a project: shell@<label> taken means
          // shell@<label>-2, -3, ...
          AgentdSessionInfo? got;
          for (var n = 1; got == null; n++) {
            try {
              got = await run(n == 1 ? null : 'shell@${_label(target)}-$n');
            } on AgentdError catch (e) {
              if (e.code != AgentdErrorCode.exists || n >= 50) rethrow;
            }
          }
          info = got;
        } else {
          final target = aliases.containsKey(p) ? p : await _absDir(hostId, await _dir(hostId, p));
          info = await c.run(target: target, harness: harness, cwd: await _home(hostId));
        }
        final s = toAgentSession(info, hostId: hostId);
        _agentd[hostId]?.upsert(info);
        _notify();
        final text = firstPrompt?.trim() ?? '';
        if (text.isNotEmpty) unawaited(_promptWhenReady(c, s.name, text));
        return s;
      case SessionSource.zellij:
      case SessionSource.tmux:
        if (h == null) throw StateError('unknown host $hostId');
        final shell = await _hosts.shell(hostId);
        final a = _muxFactory(shell, h).where((a) => a.source == where).firstOrNull;
        if (a == null) throw StateError('${where.name} is not available on $hostId');
        final s = await a.launch(session: _label(project), cwd: await _dir(hostId, project), command: _isShell(harness) ? const [] : [harness], harness: _isShell(harness) ? null : harness);
        unawaited(_pollMux(hostId));
        return s;
      case SessionSource.shell:
        final shell = await _hosts.shell(hostId);
        final dir = await _dir(hostId, project);
        final cd = 'cd ${posixDir(dir)} 2>/dev/null || cd';
        final run = _isShell(harness) ? '' : '${posixQuote(harness)}; ';
        final pty = await shell.pty(command: '$cd; $run$_loginShell', cols: 100, rows: 32);
        final label = _label(project);
        var name = 'ssh-$label';
        for (var n = 2; _shells.containsKey('$hostId/shell/$name'); n++) {
          name = 'ssh-$label-$n';
        }
        final s = AgentSession(
          hostId: hostId,
          source: SessionSource.shell,
          name: name,
          harness: _isShell(harness) ? null : harness,
          project: label,
          status: AgentStatus.idle,
          cwd: dir,
          updatedAt: DateTime.now(),
          detail: 'shell SSH',
        );
        final sh = ShellSession(s, pty);
        _shells[s.key] = sh;
        sh.done.then((_) {
          if (identical(_shells[s.key], sh)) {
            _shells.remove(s.key);
            _notify();
          }
        });
        _notify();
        return s;
    }
  }

  @override
  Future<DirListing> listDir(String hostId, String path, {bool hidden = false}) async {
    final shell = await _hosts.shell(hostId);
    final r = await shell.exec(listDirScript(path, hidden: hidden));
    return parseListDir(r.stdout, exitCode: r.exitCode, stderr: r.stderr, requested: path);
  }

  @override
  Future<void> terminate(AgentSession s) async {
    switch (s.source) {
      case SessionSource.agentd:
        final c = await _clientOf(s);
        final live = _agentd[s.hostId]?.sessions[s.name]?.status ?? s.status;
        if (live != AgentStatus.exited) {
          try {
            await c.kill(s.name, signal: 'KILL');
          } on AgentdError catch (e) {
            if (!e.isNotFound) rethrow;
          }
          await _waitExited(c, s.name);
        }
        try {
          await c.rm(s.name);
        } on AgentdError catch (e) {
          if (!e.isNotFound) rethrow;
        }
        _agentd[s.hostId]
          ?..sessions.remove(s.name)
          ..infos.remove(s.name);
        _notify();
      case SessionSource.zellij:
      case SessionSource.tmux:
        final h = _hostStatus[s.hostId];
        if (h == null) throw StateError('unknown host ${s.hostId}');
        final shell = await _hosts.shell(s.hostId);
        final a = _muxFactory(shell, h).where((a) => a.source == s.source).firstOrNull;
        if (a == null) throw StateError('${s.source.name} is not available on ${s.hostId}');
        await a.kill(s.name);
        _mux[s.hostId]?.removeWhere((m) => m.key == s.key);
        _notify();
        unawaited(_pollMux(s.hostId));
      case SessionSource.shell:
        final sh = _shells.remove(s.key);
        await sh?.close();
        _notify();
    }
  }

  /// Polls `ls` until [name] is exited or gone, at most [terminateWait].
  Future<void> _waitExited(AgentdClient c, String name) async {
    final end = DateTime.now().add(terminateWait);
    while (true) {
      final list = await c.ls();
      final i = list.where((i) => i.name == name).firstOrNull;
      if (i == null || i.state == 'exited') return;
      if (!DateTime.now().isBefore(end)) throw StateError('$name did not exit after KILL');
      await Future<void>.delayed(terminatePoll);
    }
  }

  /// Types the first prompt of a fresh session once the agent accepts it.
  Future<void> _promptWhenReady(AgentdClient c, String name, String text) async {
    final end = DateTime.now().add(promptWait);
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(promptRetry);
      try {
        await c.prompt(name, text);
        return;
      } on AgentdError catch (e) {
        final again = e.isNotReady || e.isBusy || e.code == AgentdErrorCode.starting || e.code == AgentdErrorCode.timeout;
        if (!again) return;
      } on AgentdTransportError {
        // Retry: the connection may come back.
      }
    }
  }

  Future<void> dispose() async {
    _watchers = 0;
    _viewers = 0;
    _maybeStop();
    for (final s in _shells.values.toList()) {
      await s.close();
    }
    _shells.clear();
    await _changes.close();
  }
}

/// The agentd sessions of one host, kept from its event subscription.
class _AgentdHost {
  _AgentdHost(this.repo, this.hostId, this.client);

  final LiveSessionsRepository repo;
  final String hostId;
  final AgentdClient client;
  final Map<String, AgentSession> sessions = {};
  final Map<String, AgentdSessionInfo> infos = {};
  final Map<String, Timer> _pending = {};
  StreamSubscription<AgentdEvent>? _sub;
  bool _closed = false;

  String _key(String name) => '$hostId/agentd/$name';

  String? reportedKind(String name) {
    final i = infos[name];
    return i != null && i.reported ? i.programStatus?.kind : null;
  }

  void start() {
    _sub = client.subscribe().events.listen(_on, onError: (Object _) {});
  }

  void dispose() {
    _closed = true;
    _sub?.cancel();
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
  }

  void upsert(AgentdSessionInfo info) {
    infos[info.name] = info;
    final old = sessions[info.name];
    final s = toAgentSession(info, hostId: hostId);
    final keep = s.status == AgentStatus.waiting ? old?.pending : null;
    sessions[info.name] = keep == null ? s : _copy(s, pending: keep);
    if (s.status == AgentStatus.waiting) _scheduleView(info.name);
  }

  void _snapshot(List<AgentdSessionInfo> list) {
    final names = {for (final i in list) i.name};
    sessions.removeWhere((n, _) => !names.contains(n));
    infos.removeWhere((n, _) => !names.contains(n));
    for (final i in list) {
      upsert(i);
    }
    repo._refreshFeedsOf(hostId);
  }

  void _update(String? name, AgentSession Function(AgentSession) f) {
    if (name == null) return;
    final s = sessions[name];
    if (s == null) return;
    sessions[name] = f(s);
  }

  /// Fetches the view of [name] (debounced): through its open feed when the
  /// session is on screen, else a short one for the inbox (pending question).
  void _scheduleView(String name) {
    if (_closed) return;
    if (repo._refreshFeed(_key(name))) return;
    _pending[name]?.cancel();
    _pending[name] = Timer(repo.refreshDebounce, () async {
      _pending.remove(name);
      try {
        final v = await client.view(name, linesLimit: 40);
        if (_closed) return;
        apply(name, v);
        repo._notify();
      } catch (_) {
        // The next event retries.
      }
    });
  }

  /// Applies a fetched view to the listed session; returns the SessionView.
  SessionView? apply(String name, AgentdView v) {
    final base = sessions[name];
    if (base == null || v.notModified) return null;
    final sv = toSessionView(v, base, reportedKind: reportedKind(name));
    sessions[name] = _copy(sv.session, preview: previewOf(v), clearPending: sv.session.pending == null);
    return sv;
  }

  Future<void> _resync() async {
    try {
      _snapshot(await client.ls());
      repo._notify();
    } catch (_) {}
  }

  void _on(AgentdEvent e) {
    if (_closed) return;
    final name = e.session;
    if (e is SubscribedEvent) {
      _snapshot(e.result.sessions);
    } else if (e is SessionInfoEvent) {
      upsert(e.info);
    } else if (e is SessionExitedEvent) {
      _update(name, (s) => _copy(s, status: AgentStatus.exited, clearPending: true));
      if (name != null) repo._refreshFeed(_key(name));
    } else if (e is SessionRemovedEvent) {
      if (name != null) {
        sessions.remove(name);
        infos.remove(name);
      }
    } else if (e is StatusChangedEvent) {
      final st = mapStatus(e.status);
      _update(name, (s) => withStatus(s, status: st, attention: e.attention, turn: e.turn > 0 ? e.turn : null));
      if (name != null && (st == AgentStatus.waiting || repo._feeds.containsKey(_key(name)))) _scheduleView(name);
    } else if (e is AttentionChangedEvent) {
      _update(name, (s) => _copy(s, attention: e.attention));
    } else if (e is ViewChangedEvent) {
      final s = name == null ? null : sessions[name];
      if (s != null && (s.status == AgentStatus.waiting || repo._feeds.containsKey(s.key))) _scheduleView(name!);
      return; // no list change by itself
    } else if (e is SessionLabelsEvent) {
      final i = name == null ? null : infos[name];
      if (i != null) {
        final hp = harnessAndProject(AgentdSessionInfo(name: i.name, cwd: i.cwd, cmd: i.cmd, profile: i.profile, labels: e.labels));
        _update(name, (s) => _copy(s, harness: hp.harness, project: hp.project));
      }
    } else if (e is TurnCompletedEvent) {
      final m = e.turn.message;
      if (m != null && m.isNotEmpty) _update(name, (s) => _copy(s, preview: m, turn: e.turn.turn));
    } else if (e is ResyncEvent) {
      unawaited(_resync());
      return;
    } else {
      return; // heartbeat, hello, bye, mail, disconnected...
    }
    repo._notify();
  }
}

/// The open view of one agentd session, shared by its listeners.
class _Feed {
  _Feed(this.repo, this.base);

  final LiveSessionsRepository repo;
  AgentSession base;
  final List<StreamController<SessionView>> listeners = [];
  SessionView? last;
  int _revision = 0;
  String _epoch = '';
  bool _running = false;
  bool _again = false;
  Timer? _debounce;

  _AgentdHost? get _host => repo._agentd[base.hostId];

  void refresh({bool debounce = false, bool ack = false}) {
    if (debounce) {
      _debounce?.cancel();
      _debounce = Timer(repo.refreshDebounce, () => refresh());
      return;
    }
    if (_running) {
      _again = true;
      return;
    }
    unawaited(_run(ack: ack));
  }

  Future<void> _run({bool ack = false}) async {
    final host = _host;
    if (host == null) return; // the host worker refreshes us when it starts
    _running = true;
    try {
      do {
        _again = false;
        if (ack) {
          ack = false;
          host.client.viewAck(base.name).ignore();
        }
        final v = await host.client.view(base.name, sinceRevision: _revision, epoch: _epoch, linesLimit: repo.viewLines, markup: true);
        apply(v);
      } while (_again && listeners.isNotEmpty);
    } catch (e) {
      if (last == null) {
        for (final c in [...listeners]) {
          c.addError(e);
        }
      }
    } finally {
      _running = false;
    }
  }

  void apply(AgentdView v) {
    if (v.notModified) return;
    _revision = v.revision;
    _epoch = v.epoch;
    final host = _host;
    SessionView? sv = host?.apply(base.name, v);
    if (sv == null) {
      sv = toSessionView(v, base);
    } else {
      base = host!.sessions[base.name] ?? base;
      sv = SessionView(session: base, items: sv.items, inputText: sv.inputText, ghost: sv.ghost, revision: sv.revision, epoch: sv.epoch);
    }
    last = sv;
    for (final c in [...listeners]) {
      c.add(sv);
    }
    repo._notify();
  }
}

/// Directory name for a session's uploads: the session name restricted to
/// `[A-Za-z0-9._-]` (no leading dots, so never `..`).
String uploadDirName(String sessionName) {
  final n = sessionName
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
      .replaceFirst(RegExp(r'^\.+'), '');
  return n.isEmpty ? 'session' : n;
}

/// `yyyyMMdd-HHmmss-<n>.<ext>`.
String uploadFileName(DateTime t, int n, String ext) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}-$n.$ext';
}
