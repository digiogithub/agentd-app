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
    onCancel: () => sub?.cancel(),
  );
  return c.stream;
}

/// One recorded repository call.
class FakeCall {
  const FakeCall(this.method, this.session, {this.arg, this.revision, this.epoch});
  final String method;
  final String session;
  final Object? arg;
  final int? revision;
  final String? epoch;

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
    _hosts[i] = HostStatus(h.config, state: HostState.online, capabilities: h.capabilities ?? sampleHosts[2].capabilities, sessionCount: h.sessionCount);
    _changes.add(null);
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

  AgentSession? byKey(String key) => _sessions[key];

  @override
  Stream<List<AgentSession>> watch() => _replay(() => List<AgentSession>.unmodifiable(_sessions.values), _changes.stream);

  SessionView _view(String key) {
    final s = _sessions[key]!;
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
    return _replay(
      () => _view(key),
      _changes.stream,
    ).distinct((a, b) => identical(a.session, b.session) && a.items.length == b.items.length && a.revision == b.revision);
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
        SessionSource.agentd => '$harness@$project',
        SessionSource.shell => 'ssh-$project',
        _ => project,
      },
      harness: harness,
      project: project,
      status: AgentStatus.starting,
      cwd: '~/src/$project',
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
