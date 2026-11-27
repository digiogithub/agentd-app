// Fake repositories with the sample data of the mockups. They keep state in
// memory, push every change to their streams and record the calls they get,
// so widget tests can assert on them.

import 'dart:async';
import 'dart:typed_data';

import '../../core/contracts.dart';
import 'fake_shell.dart';
import 'sample_data.dart';

/// Stream that replays the current value to each new listener, then follows
/// [changes].
Stream<T> _replay<T>(T Function() current, Stream<void> changes) {
  late StreamController<T> c;
  StreamSubscription<void>? sub;
  c = StreamController<T>(
    onListen: () {
      c.add(current());
      sub = changes.listen((_) => c.add(current()));
    },
    // Not returned: `stream.first` waits for the future of onCancel.
    onCancel: () {
      sub?.cancel();
    },
  );
  return c.stream;
}

/// One recorded repository call.
class FakeCall {
  const FakeCall(this.method, this.session, {this.arg, this.revision, this.epoch, this.notify});
  final String method;
  final String session;
  final Object? arg;
  final int? revision;
  final String? epoch;

  /// `notify` of a board answer (null for other calls).
  final bool? notify;

  @override
  String toString() => 'FakeCall($method, $session, $arg, $revision, $epoch)';
}

class FakeHostsRepository implements HostsRepository {
  FakeHostsRepository({List<HostStatus>? hosts}) : _hosts = [...(hosts ?? sampleHosts)];

  final List<HostStatus> _hosts;
  final _changes = StreamController<void>.broadcast();
  final List<String> connected = [];
  static const fakePublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForPreviewsOnly0agentdApp agentd-app@movil';

  List<HostStatus> get hosts => List.unmodifiable(_hosts);

  @override
  Stream<List<HostStatus>> watch() => _replay(() => List<HostStatus>.unmodifiable(_hosts), _changes.stream);

  @override
  Future<void> save(HostConfig config) async {
    final i = _hosts.indexWhere((h) => h.config.id == config.id);
    if (i >= 0) {
      final old = _hosts[i];
      _hosts[i] = HostStatus(config, state: old.state, capabilities: old.capabilities, error: old.error, sessionCount: old.sessionCount);
    } else {
      _hosts.add(HostStatus(config));
    }
    _changes.add(null);
  }

  @override
  Future<void> remove(String hostId) async {
    _hosts.removeWhere((h) => h.config.id == hostId);
    _changes.add(null);
  }

  @override
  Future<void> connect(String hostId) async {
    connected.add(hostId);
    final i = _hosts.indexWhere((h) => h.config.id == hostId);
    if (i < 0) return;
    final h = _hosts[i];
    _hosts[i] = HostStatus(h.config, state: HostState.online, capabilities: h.capabilities ?? (h.config.isRelay ? _relayCaps : sampleHosts[2].capabilities), sessionCount: h.sessionCount);
    _changes.add(null);
  }

  static const _relayCaps = HostCapabilities(agentdSocket: 'relay', tools: {'agentd': ToolInfo('agentd', installed: true)});

  /// Hosts closed with [disconnect], in order.
  final List<String> disconnected = [];

  @override
  Future<void> disconnect(String hostId) async {
    disconnected.add(hostId);
    final i = _hosts.indexWhere((h) => h.config.id == hostId);
    if (i < 0) return;
    final h = _hosts[i];
    _hosts[i] = HostStatus(h.config, capabilities: h.capabilities, sessionCount: h.sessionCount);
    _changes.add(null);
  }

  @override
  Future<void> disconnectAll() async {
    for (final h in [..._hosts]) {
      await disconnect(h.config.id);
    }
  }

  /// Times [reconnectAll] was called.
  int reconnects = 0;

  @override
  Future<void> reconnectAll() async {
    reconnects++;
    for (final h in [..._hosts]) {
      if (h.state != HostState.online) await connect(h.config.id);
    }
  }

  @override
  Future<String> publicKey() async => fakePublicKey;

  /// Shells handed out by [shell], by host id.
  final Map<String, FakeRemoteShell> shells = {};

  /// Hosts enrolled with a password (the password itself is not kept).
  final List<String> enrolled = [];

  @override
  Future<RemoteShell> shell(String hostId) async {
    final caps = _hosts.where((h) => h.config.id == hostId).map((h) => h.capabilities).firstOrNull;
    return shells[hostId] ??= FakeRemoteShell(hostId, caps: caps ?? const HostCapabilities());
  }

  /// Relay links paired with [pairRelay] (the code is not kept: only the
  /// count matters to tests).
  int relayPairings = 0;

  /// When set, [pairRelay] waits for it before succeeding (shows the
  /// "approve on the host" state).
  Completer<void>? pairApproval;

  /// When set, [pairRelay] throws it.
  Object? pairError;

  /// Scope given to hosts paired with [pairRelay].
  RelayScope pairScope = RelayScope.operate;

  @override
  Future<HostConfig> pairRelay(String link, {required String deviceName, void Function(RelayPairPhase phase)? onPhase}) async {
    final found = relayLinkCandidates(link);
    final u = found.isEmpty ? null : Uri.tryParse(found.first);
    if (u == null) throw const FormatException('not an agentd relay link');
    onPhase?.call(RelayPairPhase.connecting);
    final err = pairError;
    if (err != null) throw err;
    onPhase?.call(RelayPairPhase.waitingApproval);
    await pairApproval?.future;
    relayPairings++;
    final label = u.queryParameters['h'] ?? 'relay';
    final config = HostConfig(
      id: 'relay-$label',
      name: label,
      host: Uri.tryParse(u.queryParameters['u'] ?? '')?.host ?? 'relay',
      port: 0,
      user: '',
      transport: HostTransport.relay,
      relay: RelayHostInfo(relayUrl: u.queryParameters['u'] ?? '', route: u.queryParameters['r'] ?? '', hostKey: u.queryParameters['k'] ?? '', deviceId: 'dfake', scope: pairScope, kind: 'owner', label: label),
    );
    await save(config);
    await connect(config.id);
    return config;
  }

  @override
  Future<ByteChannel> agentdChannel(String hostId) async => throw UnsupportedError('the fake has no daemon');

  @override
  Future<HostConfig> enrollWithPassword(HostConfig config, String password) async {
    if (password.isEmpty) throw ArgumentError('empty password');
    enrolled.add(config.id);
    final saved = config.copyWith(auth: AuthKind.generatedKey);
    await save(saved);
    return saved;
  }
}

class FakeSessionsRepository implements SessionsRepository {
  FakeSessionsRepository({List<AgentSession>? sessions, DateTime? now}) {
    final t = now ?? DateTime.now();
    for (final s in sessions ?? sampleSessions(t)) {
      _sessions[s.key] = s;
      _items[s.key] = sampleItems(s);
    }
  }

  final _sessions = <String, AgentSession>{};
  final _items = <String, List<ChatItem>>{};
  final _revisions = <String, int>{};
  final _changes = StreamController<void>.broadcast();
  final List<FakeCall> calls = [];
  final List<FakePty> ptys = [];

  /// When set, [choose] fails with this error (to test error handling).
  Object? chooseError;
  Object? promptError;

  /// Per-session prompt failures, by session name (partial broadcast).
  final Map<String, Object> promptErrors = {};

  AgentSession? byKey(String key) => _sessions[key];

  @override
  Stream<List<AgentSession>> watch() => _replay(() => List<AgentSession>.unmodifiable(_sessions.values), _changes.stream);

  SessionView? _view(String key) {
    final s = _sessions[key];
    if (s == null) return null; // terminated while open
    final rev = _revisions[key] ?? (s.pending?.revision ?? 1);
    return SessionView(
      session: s,
      items: List.unmodifiable(_items[key] ?? const []),
      ghost: s.harness == 'claude' ? 'run the hc listener tests' : null,
      revision: rev,
      epoch: kEpoch,
    );
  }

  @override
  Stream<SessionView> view(AgentSession session) {
    final key = session.key;
    if (!_sessions.containsKey(key)) _sessions[key] = session;
    return _replay<SessionView?>(
      () => _view(key),
      _changes.stream,
    ).where((v) => v != null).cast<SessionView>().distinct((a, b) => identical(a.session, b.session) && a.items.length == b.items.length && a.revision == b.revision);
  }

  void _update(AgentSession s, {AgentStatus? status, bool clearPending = false, String? preview}) {
    final cur = _sessions[s.key] ?? s;
    _sessions[s.key] = AgentSession(
      hostId: cur.hostId,
      source: cur.source,
      name: cur.name,
      harness: cur.harness,
      project: cur.project,
      status: status ?? cur.status,
      attention: false,
      preview: preview ?? cur.preview,
      cwd: cur.cwd,
      turn: cur.turn,
      updatedAt: DateTime.now(),
      pending: clearPending ? null : cur.pending,
      detail: cur.detail,
    );
    _revisions[s.key] = (_revisions[s.key] ?? cur.pending?.revision ?? 1) + 1;
  }

  void _addItem(String key, ChatItem item) => _items[key] = [...?_items[key], item];

  @override
  Future<void> prompt(AgentSession s, String text) async {
    calls.add(FakeCall('prompt', s.name, arg: text));
    if (promptError != null) throw promptError!;
    if (promptErrors[s.name] case final e?) {
      throw e;
    }
    _addItem(s.key, ChatItem(role: ChatRole.user, text: text));
    _update(s, status: AgentStatus.working, preview: text);
    _changes.add(null);
  }

  @override
  Future<void> choose(AgentSession s, SessionOption option, {required int revision, required String epoch}) async {
    calls.add(FakeCall('choose', s.name, arg: option.id, revision: revision, epoch: epoch));
    if (chooseError != null) throw chooseError!;
    _addItem(s.key, ChatItem(role: ChatRole.system, text: 'Elegido: ${option.label}'));
    _update(s, status: AgentStatus.working, clearPending: true);
    _changes.add(null);
  }

  @override
  Future<void> keys(AgentSession s, List<String> keys) async {
    calls.add(FakeCall('keys', s.name, arg: List<String>.unmodifiable(keys)));
  }

  /// Image uploads received: remote path -> size in bytes.
  final Map<String, int> uploads = {};

  /// When set, [uploadImage] fails with this error (to test error handling).
  Object? uploadError;

  /// Hosts whose uploads are refused by [canUploadImages] (relay host with
  /// an older daemon).
  final Set<String> noUploads = {};

  @override
  Future<bool> canUploadImages(AgentSession s) async => !noUploads.contains(s.hostId);

  @override
  Future<String> uploadImage(
    AgentSession s,
    Uint8List bytes, {
    required String extension,
  }) async {
    calls.add(FakeCall('uploadImage', s.name, arg: extension));
    if (uploadError != null) throw uploadError!;
    final path =
        '/home/demo/.cache/agentd-app/uploads/${s.name}/20261116-100000-${uploads.length + 1}.$extension';
    uploads[path] = bytes.length;
    return path;
  }

  @override
  Future<void> interrupt(AgentSession s) async {
    calls.add(FakeCall('interrupt', s.name));
    _addItem(s.key, const ChatItem(role: ChatRole.system, text: 'Interrumpido'));
    _update(s, status: AgentStatus.idle, clearPending: true);
    _changes.add(null);
  }

  @override
  Future<PtySession> terminal(AgentSession s, {int cols = 80, int rows = 24, bool observe = false}) async {
    calls.add(FakeCall('terminal', s.name, arg: observe));
    final pty = FakePty(screen: sampleTerminalScreen, cols: cols, rows: rows);
    ptys.add(pty);
    return pty;
  }

  @override
  Future<AgentSession> launch({
    required String hostId,
    required SessionSource where,
    required String project,
    required String harness,
    String? firstPrompt,
  }) async {
    calls.add(FakeCall('launch', '$harness@$project', arg: {'host': hostId, 'where': where.name, 'firstPrompt': firstPrompt}));
    final s = AgentSession(
      hostId: hostId,
      source: where,
      name: switch (where) {
        SessionSource.agentd => '${harness.isEmpty || harness == 'bash' ? kShellHarness : harness}@${project.split('/').where((p) => p.isNotEmpty).lastOrNull ?? project}',
        SessionSource.shell => 'ssh-$project',
        _ => project,
      },
      harness: harness,
      project: project,
      status: AgentStatus.starting,
      cwd: project.startsWith('/') ? project : '~/src/$project',
      turn: 0,
      updatedAt: DateTime.now(),
    );
    _sessions[s.key] = s;
    _items[s.key] = [if (firstPrompt != null && firstPrompt.isNotEmpty) ChatItem(role: ChatRole.user, text: firstPrompt)];
    _changes.add(null);
    return s;
  }

  @override
  Future<List<String>> projects(String hostId) async => sampleAliases[hostId] ?? const [];

  /// When set, [terminate] fails with this error.
  Object? terminateError;

  @override
  Future<void> terminate(AgentSession s) async {
    calls.add(FakeCall('terminate', s.name));
    if (terminateError != null) throw terminateError!;
    _sessions.remove(s.key);
    _items.remove(s.key);
    _changes.add(null);
  }

  /// Folders of the in-memory host tree: path -> children (`name` enterable,
  /// `name!` not). Home is [fakeHome]; the tree also has dirs above it.
  static const fakeHome = '/home/demo';
  static const fakeTree = <String, List<String>>{
    '/': ['home', 'srv', 'tmp', 'root!'],
    '/home': ['demo', 'other!'],
    '/home/demo': ['src', 'docs', 'Música', '.config', '.cache'],
    '/home/demo/src': ['webapp', 'api', 'agentd'],
    '/home/demo/src/webapp': [],
    '/home/demo/src/api': [],
    '/home/demo/src/agentd': [],
    '/home/demo/docs': [],
    '/home/demo/Música': [],
    '/home/demo/.config': ['agentd'],
    '/home/demo/.config/agentd': [],
    '/home/demo/.cache': [],
    '/srv': ['www'],
    '/srv/www': [],
    '/tmp': [],
  };

  /// Paths asked to [listDir], in order.
  final List<String> listed = [];

  @override
  Future<DirListing> listDir(String hostId, String path, {bool hidden = false}) async {
    listed.add(path);
    var p = path.isEmpty ? fakeHome : path;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    final kids = fakeTree[p];
    if (kids == null) throw ListDirException(ListDirFailure.notFound, path);
    final entries = [
      for (final k in kids)
        if (hidden || !k.startsWith('.')) DirEntry(k.endsWith('!') ? k.substring(0, k.length - 1) : k, enterable: !k.endsWith('!')),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return DirListing(path: p, home: fakeHome, entries: entries);
  }
}

class FakeMailRepository implements MailRepository {
  FakeMailRepository({Map<String, List<MailMessage>>? mail, DateTime? now})
    : _mail = mail ?? {'estudio': sampleMail(now ?? DateTime.now()), 'vps-hetzner': sampleMail(now ?? DateTime.now())};

  final Map<String, List<MailMessage>> _mail;
  final _changes = StreamController<void>.broadcast();
  final List<FakeCall> sent = [];
  int _nextId = 200;

  List<MailMessage> _of(String hostId) => List.unmodifiable(_mail[hostId] ?? const []);

  @override
  Stream<List<MailMessage>> inbox(String hostId) => _replay(() => _of(hostId), _changes.stream);

  @override
  Stream<List<WorkQueue>> queues(String hostId) => _replay(() {
    final counts = <String, int>{};
    for (final m in _of(hostId)) {
      if (m.queue == null) continue;
      counts[m.queue!] = (counts[m.queue!] ?? 0) + (m.state == MailState.unclaimed ? 1 : 0);
    }
    return [for (final e in counts.entries) WorkQueue(e.key, e.value)];
  }, _changes.stream);

  @override
  Future<void> send(String hostId, {required String to, required String body, String subject = ''}) async {
    sent.add(FakeCall('send', to, arg: body));
    final queue = to.startsWith('queue:') ? to.substring(6) : null;
    (_mail[hostId] ??= []).add(
      MailMessage(
        id: _nextId++,
        from: 'human:jose',
        to: to,
        subject: subject,
        body: body,
        state: queue != null ? MailState.unclaimed : MailState.queued,
        createdAt: DateTime.now(),
        queue: queue,
      ),
    );
    _changes.add(null);
  }
}

class FakeBoardRepository implements BoardRepository {
  FakeBoardRepository({Map<String, HostBoard>? boards, DateTime? now}) : _boards = {...(boards ?? sampleBoards(now ?? DateTime.now()))};

  final Map<String, HostBoard> _boards;
  final _changes = StreamController<void>.broadcast();

  /// Recorded answers: `session` is the question id, `arg` the body.
  final List<FakeCall> calls = [];

  /// When set, [answer] fails with this error.
  Object? answerError;

  /// Replaces the board of a host (tests).
  void set(HostBoard board) {
    _boards[board.hostId] = board;
    _changes.add(null);
  }

  @override
  Stream<HostBoard> watch(String hostId) => _replay(() => _boards[hostId] ?? HostBoard(hostId: hostId, available: false), _changes.stream);

  @override
  Future<void> answer(String hostId, int questionId, String body, {bool notify = true}) async {
    calls.add(FakeCall('answer', '$questionId', arg: body, notify: notify));
    if (answerError != null) throw answerError!;
    final b = _boards[hostId];
    if (b == null) return;
    // Like the daemon: a reply closes the question.
    _boards[hostId] = HostBoard(
      hostId: hostId,
      unreadHuman: b.unreadHuman,
      notes: b.notes,
      backlog: b.backlog,
      sessions: [
        for (final s in b.sessions)
          BoardSession(
            hostId: s.hostId,
            name: s.name,
            status: s.status,
            attention: s.attention,
            turn: s.turn,
            preview: s.preview,
            tasks: s.tasks,
            questions: [for (final q in s.questions) if (q.id != questionId) q],
          ),
      ],
    );
    _changes.add(null);
  }

  /// When set, every backlog change fails with it.
  Object? noteError;

  /// Warning returned by the next [assignNote].
  String? assignWarning;

  int _noteId = 100;

  /// Replaces the notes of a host, like the daemon orders them.
  void _setNotes(String hostId, List<BacklogNote> notes, {List<BoardSession>? sessions}) {
    final b = _boards[hostId]!;
    int rank(BacklogNote n) => n.state.index;
    final sorted = [...notes]..sort((a, c) => rank(a) != rank(c) ? rank(a) - rank(c) : (c.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
    _boards[hostId] = HostBoard(hostId: hostId, sessions: sessions ?? b.sessions, unreadHuman: b.unreadHuman, available: b.available, notes: sorted, backlog: true);
    _changes.add(null);
  }

  HostBoard _backlogOf(String hostId, String method, int id, Object? arg) {
    calls.add(FakeCall(method, '$id', arg: arg));
    if (noteError != null) throw noteError!;
    final b = _boards[hostId];
    if (b == null || !b.backlog) throw const BacklogException(BacklogFailure.unavailable);
    return b;
  }

  BacklogNote _note(HostBoard b, int id) => b.notes.where((n) => n.id == id).firstOrNull ?? (throw const BacklogException(BacklogFailure.notFound));

  @override
  Future<BacklogNote> addNote(String hostId, {required String title, String body = ''}) async {
    final b = _backlogOf(hostId, 'addNote', 0, (title, body));
    if (title.trim().isEmpty || title.runes.length > BacklogNote.maxTitle || body.runes.length > BacklogNote.maxBody) throw const BacklogException(BacklogFailure.invalid);
    final now = DateTime.now();
    final n = BacklogNote(id: ++_noteId, title: title.trim(), body: body, createdAt: now, updatedAt: now);
    _setNotes(hostId, [n, ...b.notes]);
    return n;
  }

  @override
  Future<BacklogNote> updateNote(String hostId, int noteId, {String? title, String? body, bool reopen = false}) async {
    final b = _backlogOf(hostId, 'updateNote', noteId, (title, body, reopen));
    final old = _note(b, noteId);
    if (title != null && title.trim().isEmpty) throw const BacklogException(BacklogFailure.invalid);
    final n = BacklogNote(
      id: old.id,
      title: title?.trim() ?? old.title,
      body: body ?? old.body,
      state: reopen ? NoteState.open : old.state,
      assignedTo: reopen ? null : old.assignedTo,
      taskId: reopen ? null : old.taskId,
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
      assignedAt: reopen ? null : old.assignedAt,
      doneAt: reopen ? null : old.doneAt,
    );
    _setNotes(hostId, [for (final x in b.notes) x.id == noteId ? n : x]);
    return n;
  }

  @override
  Future<void> removeNote(String hostId, int noteId) async {
    final b = _backlogOf(hostId, 'removeNote', noteId, null);
    _note(b, noteId);
    _setNotes(hostId, [for (final x in b.notes) if (x.id != noteId) x]);
  }

  @override
  Future<String?> assignNote(String hostId, int noteId, {required String session, bool inProgress = false}) async {
    final b = _backlogOf(hostId, 'assignNote', noteId, (session, inProgress));
    final old = _note(b, noteId);
    if (old.state == NoteState.done) throw const BacklogException(BacklogFailure.invalid);
    if (!b.sessions.any((s) => s.name == session)) throw const BacklogException(BacklogFailure.notFound);
    final now = DateTime.now();
    final n = BacklogNote(id: old.id, title: old.title, body: old.body, state: NoteState.assigned, assignedTo: session, taskId: 'n${old.id}', createdAt: old.createdAt, updatedAt: now, assignedAt: now);
    final task = AgentTask(id: 'n${old.id}', title: old.title, status: inProgress ? TaskStatus.inProgress : TaskStatus.pending, note: old.body.isEmpty ? null : old.body, updatedAt: now, fromBacklog: true);
    // Like the daemon: the note is a task of the session's list.
    _setNotes(
      hostId,
      [for (final x in b.notes) x.id == noteId ? n : x],
      sessions: [
        for (final s in b.sessions)
          s.name != session
              ? s
              : BoardSession(
                  hostId: s.hostId,
                  name: s.name,
                  status: s.status,
                  attention: s.attention,
                  turn: s.turn,
                  preview: s.preview,
                  tasks: [for (final t in s.tasks) if (t.id != task.id) t, task],
                  questions: s.questions,
                ),
      ],
    );
    final w = assignWarning;
    assignWarning = null;
    return w;
  }
}

/// Devices of the sample hosts. A relay host lists this app first
/// ([HostConfig.relay] device id); one that may not manage devices lists only
/// itself, like the daemon.
class FakeDevicesRepository implements DevicesRepository {
  FakeDevicesRepository(this._hosts, {DateTime? now}) : _now = now ?? DateTime.now();

  final HostsRepository _hosts;
  final DateTime _now;
  final Map<String, List<PairedDevice>> _devices = {};

  /// Recorded revokes: `session` is the host, `arg` the device id.
  final List<FakeCall> calls = [];

  /// When set, [devices] / [revoke] fail with it.
  Object? listError;
  Object? revokeError;

  Future<HostConfig?> _config(String hostId) async => (await _hosts.watch().first).where((h) => h.config.id == hostId).firstOrNull?.config;

  List<PairedDevice> _seed(HostConfig? c) => [
    if (c?.relay != null)
      PairedDevice(id: c!.relay!.deviceId, name: 'Este móvil', platform: 'android', scope: c.relay!.scope, sessions: c.relay!.sessions, guest: c.relay!.kind == 'guest', createdAt: _now.subtract(const Duration(days: 3)), lastSeen: _now, online: true),
    PairedDevice(id: 'dpixel0000001', name: 'Pixel de Ana', platform: 'android', scope: RelayScope.operate, createdAt: _now.subtract(const Duration(days: 20)), lastSeen: _now.subtract(const Duration(hours: 3))),
    PairedDevice(id: 'dmacbook00001', name: 'MacBook', platform: 'macos', scope: RelayScope.admin, createdAt: _now.subtract(const Duration(days: 40)), lastSeen: _now.subtract(const Duration(minutes: 1)), online: true),
    PairedDevice(
      id: 'dinvitado0001',
      name: 'iPad de visita',
      platform: 'ios',
      scope: RelayScope.view,
      sessions: const ['claude@docs'],
      guest: true,
      createdAt: _now.subtract(const Duration(days: 1)),
      expiresAt: _now.add(const Duration(days: 6)),
    ),
  ];

  @override
  Future<List<PairedDevice>> devices(String hostId) async {
    if (listError != null) throw listError!;
    final c = await _config(hostId);
    final own = c?.relay?.deviceId;
    final all = _devices[hostId] ??= _seed(c);
    return [
      for (final d in all)
        if (c == null || c.canManageDevices || d.id == own)
          PairedDevice(
            id: d.id,
            name: d.name,
            platform: d.platform,
            scope: d.scope,
            sessions: d.sessions,
            guest: d.guest,
            createdAt: d.createdAt,
            expiresAt: d.expiresAt,
            lastSeen: d.lastSeen,
            online: d.online,
            isThisDevice: d.id == own,
          ),
    ];
  }

  @override
  Future<void> revoke(String hostId, String deviceId) async {
    calls.add(FakeCall('revoke', hostId, arg: deviceId));
    if (revokeError != null) throw revokeError!;
    final c = await _config(hostId);
    final own = c?.relay?.deviceId;
    if (c != null && !c.canManageDevices && deviceId != own) throw const DevicesException(DevicesFailure.forbidden);
    final all = _devices[hostId] ??= _seed(c);
    if (!all.any((d) => d.id == deviceId)) throw const DevicesException(DevicesFailure.notFound);
    all.removeWhere((d) => d.id == deviceId);
    if (deviceId == own) await _hosts.remove(hostId);
  }
}

class FakeProvisionService implements ProvisionService {
  FakeProvisionService({this.stepDelay = const Duration(milliseconds: 250), this.failAt});

  final Duration stepDelay;

  /// Step whose event carries an error (none by default).
  final ProvisionStep? failAt;
  int installs = 0;

  @override
  Future<HostCapabilities> detect(RemoteShell shell) async =>
      shell is FakeRemoteShell && shell.caps.tools.isNotEmpty ? shell.caps : sampleHosts[2].capabilities!;

  static const cliPackages = {
    'claude': 'npm i -g @anthropic-ai/claude-code',
    'codex': 'npm i -g @openai/codex',
    'pando': 'curl -fsSL …/pando/releases/latest | sh',
    'opencode': 'npm i -g opencode-ai',
    'gemini': 'npm i -g @google/gemini-cli',
  };

  @override
  List<PlannedStep> planSteps(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) {
    final cmds = plan(caps, agentd: agentd, hcListener: hcListener, mcp: mcp, clis: clis);
    return [for (final c in cmds) PlannedStep(step: ProvisionStep.install, title: c.split(' ').take(2).join(' '), command: c, group: 'fake')];
  }

  @override
  List<String> plan(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) {
    final arch = caps.arch == 'aarch64' || caps.arch == 'arm64' ? 'arm64' : 'amd64';
    final os = caps.os == 'Darwin' ? 'darwin' : 'linux';
    return [
      if (agentd) ...[
        'curl -fsSLO …/agentd_0.6.2_${os}_$arch.tar.gz',
        'sha256sum -c checksums.txt',
        'tar -xzf agentd_0.6.2_${os}_$arch.tar.gz -C ~/.local/bin agentd',
        'systemctl --user enable --now agentd',
      ],
      if (agentd && hcListener) 'agentd config set herdr.listen true',
      for (final c in clis) cliPackages[c] ?? 'install $c',
      if (agentd && mcp) 'agentd mcp install',
    ];
  }

  @override
  Stream<ProvisionEvent> install(
    RemoteShell shell,
    HostCapabilities caps, {
    bool agentd = true,
    bool hcListener = true,
    bool mcp = true,
    Set<String> clis = const {},
  }) async* {
    installs++;
    final steps = <(ProvisionStep, String)>[
      if (agentd) ...[
        (ProvisionStep.download, 'Descargando agentd 0.6.2'),
        (ProvisionStep.verify, 'Comprobando la suma SHA-256'),
        (ProvisionStep.install, 'Instalando en ~/.local/bin'),
        (ProvisionStep.service, 'Activando el servicio de usuario'),
      ],
      if (agentd && hcListener) (ProvisionStep.hcListener, 'Activando el listener herdr-core'),
      for (final c in clis) (ProvisionStep.cli, 'Instalando $c'),
      if (agentd && mcp) (ProvisionStep.mcp, 'Registrando el MCP de agentd'),
    ];
    var failed = false;
    for (final (step, msg) in steps) {
      if (failed) {
        yield ProvisionEvent(step, msg, skipped: true);
        continue;
      }
      yield ProvisionEvent(step, msg);
      await Future<void>.delayed(stepDelay);
      if (step == failAt) {
        yield ProvisionEvent(step, msg, done: true, error: 'el comando terminó con código 1');
        failed = true;
        continue;
      }
      yield ProvisionEvent(step, msg, done: true);
    }
  }
}

/// Push registrations in memory (fakes, tests).
class FakePushRepository implements PushRepository {
  /// hostId → token registered there.
  final Map<String, String> registered = {};
  final List<String> calls = [];

  /// Hosts that refuse (an older daemon, a guest device).
  final Set<String> refusing = {};

  @override
  Future<bool> register(String hostId, {required String token, required String deviceName}) async {
    calls.add('register $hostId');
    if (refusing.contains(hostId)) return false;
    registered[hostId] = token;
    return true;
  }

  @override
  Future<void> unregister(String hostId, {required String token}) async {
    calls.add('unregister $hostId');
    if (registered[hostId] == token) registered.remove(hostId);
  }
}
