// Shared contracts between the app layers. Every layer codes against these
// types; implementations live in their own folders:
//
//   lib/src/transport/  SSH (RemoteShell, HostKeyStore, KeyStore)
//   lib/src/relay/      agentd-relay tunnel (Noise + stream mux over WebSocket)
//   lib/src/agentd/     agentd wire protocol over a ByteChannel
//   lib/src/mux/        zellij / tmux over a RemoteShell
//   lib/src/provision/  host detection and installs over a RemoteShell
//   lib/src/ui/         screens; consumes the repositories below
//   lib/src/data/       repositories wiring the layers together
//
// Change this file only with the integrator: it is the only cross-layer API.

import 'dart:async';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

/// Result of a non-interactive remote command.
class ExecResult {
  const ExecResult(this.exitCode, this.stdout, this.stderr);
  final int? exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
}

/// A bidirectional byte stream (an SSH channel to a unix socket, a PTY...).
abstract class ByteChannel {
  Stream<Uint8List> get stream;
  void add(List<int> data);
  Future<void> close();

  /// Completes when the remote side closes.
  Future<void> get done;
}

/// An interactive program running in a remote PTY.
abstract class PtySession implements ByteChannel {
  void resize(int cols, int rows);

  /// Exit code when the program exits (null if unknown).
  Future<int?> get exitCode;
}

/// What the app can do on one connected host. Implemented by the SSH layer.
abstract class RemoteShell {
  /// Runs [command] through the login shell (`sh -lc`), stdin closed.
  Future<ExecResult> exec(String command, {Duration timeout = const Duration(seconds: 30), String? stdin});

  /// Starts [command] (or the login shell when null) in a PTY.
  Future<PtySession> pty({String? command, int cols = 80, int rows = 24, Map<String, String> env = const {}});

  /// Opens a channel to a unix socket on the host (OpenSSH
  /// `direct-streamlocal@openssh.com`). Used for the agentd daemon socket.
  Future<ByteChannel> openUnixSocket(String path);

  /// Writes [data] to [path] on the host (parent directories are created),
  /// replacing any file there. [mode] is the POSIX permission, 0600 by default.
  Future<void> writeFile(String path, Uint8List data, {int mode = 0x180});

  Future<void> close();
  bool get isClosed;
}

enum AuthKind { generatedKey, importedKey, password }

/// How the app reaches a host: SSH (shell, multiplexers, provisioning and
/// the agentd socket) or an agentd-relay tunnel (agentd sessions only).
enum HostTransport { ssh, relay }

/// Permission scope of a relay device, lowest first (agentd design
/// relay-transport §5). The daemon enforces it; the UI hides what it forbids.
enum RelayScope {
  /// Watch sessions, chat views and terminals (observe only).
  view,

  /// Also prompt, answer approvals, type in terminals, mailbox.
  operate,

  /// Also start, kill and remove sessions.
  admin;

  static RelayScope parse(String? s) => RelayScope.values.where((v) => v.name == s).firstOrNull ?? RelayScope.view;
}

/// A host paired through agentd-relay. No secret here: the device's X25519
/// private key is in the secure store under [HostConfig.keyId].
class RelayHostInfo {
  const RelayHostInfo({
    required this.relayUrl,
    required this.route,
    required this.hostKey,
    required this.deviceId,
    this.scope = RelayScope.view,
    this.sessions = const [],
    this.kind = '',
    this.label = '',
  });

  /// Base URL of the relay (https/wss; http/ws only on loopback).
  final String relayUrl;
  final String route;

  /// Pinned host X25519 public key, base64url (from the invite).
  final String hostKey;
  final String deviceId;
  final RelayScope scope;

  /// Session name globs this device may see (empty = all).
  final List<String> sessions;

  /// owner | guest.
  final String kind;

  /// Host label reported by the host.
  final String label;

  RelayHostInfo copyWith({RelayScope? scope, List<String>? sessions, String? kind, String? label}) => RelayHostInfo(
    relayUrl: relayUrl,
    route: route,
    hostKey: hostKey,
    deviceId: deviceId,
    scope: scope ?? this.scope,
    sessions: sessions ?? this.sessions,
    kind: kind ?? this.kind,
    label: label ?? this.label,
  );

  Map<String, Object?> toJson() => {
    'relayUrl': relayUrl,
    'route': route,
    'hostKey': hostKey,
    'deviceId': deviceId,
    'scope': scope.name,
    'sessions': sessions,
    'kind': kind,
    'label': label,
  };

  factory RelayHostInfo.fromJson(Map<String, Object?> j) => RelayHostInfo(
    relayUrl: j['relayUrl'] as String,
    route: j['route'] as String,
    hostKey: j['hostKey'] as String,
    deviceId: j['deviceId'] as String? ?? '',
    scope: RelayScope.parse(j['scope'] as String?),
    sessions: [for (final s in (j['sessions'] as List?) ?? const []) s as String],
    kind: j['kind'] as String? ?? '',
    label: j['label'] as String? ?? '',
  );

  bool sameAs(RelayHostInfo o) =>
      o.relayUrl == relayUrl && o.route == route && o.hostKey == hostKey && o.deviceId == deviceId && o.scope == scope && o.kind == kind && o.label == label && o.sessions.join('\n') == sessions.join('\n');
}

/// A saved host. Secrets (private keys, passwords) are never in here: they
/// are in the secure store under [keyId].
class HostConfig {
  const HostConfig({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.user,
    this.auth = AuthKind.generatedKey,
    this.keyId,
    this.hostKeyFingerprint,
    this.transport = HostTransport.ssh,
    this.relay,
  });

  final String id;
  final String name;

  /// SSH: address. Relay: the relay's host name (display only).
  final String host;
  final int port;
  final String user;
  final AuthKind auth;
  final String? keyId;

  /// SHA256 fingerprint accepted on first connect (trust on first use).
  final String? hostKeyFingerprint;

  final HostTransport transport;

  /// Set for [HostTransport.relay].
  final RelayHostInfo? relay;

  bool get isRelay => transport == HostTransport.relay;

  /// A shell on the host: zellij/tmux, plain shells, folders, uploads,
  /// provisioning. SSH only.
  bool get hasShell => !isRelay;

  /// May prompt, answer approvals, type in terminals (relay: operate+).
  bool get canOperate => !isRelay || (relay?.scope.index ?? 0) >= RelayScope.operate.index;

  /// May read and write the host's backlog notes: a human on SSH, or an
  /// owner relay device with the operate scope that is not limited to some
  /// sessions (the daemon answers `forbidden` to the others).
  bool get canBacklog => !isRelay || (canOperate && relay?.kind != 'guest' && (relay?.sessions.isEmpty ?? true));

  /// May list and revoke every device paired with the host: a human on SSH,
  /// or an owner relay device with the admin scope that is not limited to
  /// some sessions. Any other relay device sees and revokes only itself.
  bool get canManageDevices => !isRelay || (canAdmin && relay?.kind != 'guest' && (relay?.sessions.isEmpty ?? true));

  /// May start and terminate sessions (relay: admin).
  bool get canAdmin => !isRelay || relay?.scope == RelayScope.admin;

  HostConfig copyWith({
    String? name,
    String? host,
    int? port,
    String? user,
    AuthKind? auth,
    String? keyId,
    String? hostKeyFingerprint,
    RelayHostInfo? relay,
  }) => HostConfig(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    user: user ?? this.user,
    auth: auth ?? this.auth,
    keyId: keyId ?? this.keyId,
    hostKeyFingerprint: hostKeyFingerprint ?? this.hostKeyFingerprint,
    transport: transport,
    relay: relay ?? this.relay,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'user': user,
    'auth': auth.name,
    'keyId': keyId,
    'hostKeyFingerprint': hostKeyFingerprint,
    if (isRelay) 'transport': transport.name,
    if (relay != null) 'relay': relay!.toJson(),
  };

  factory HostConfig.fromJson(Map<String, Object?> j) => HostConfig(
    id: j['id'] as String,
    name: j['name'] as String,
    host: j['host'] as String,
    port: (j['port'] as num?)?.toInt() ?? 22,
    user: j['user'] as String,
    auth: AuthKind.values.byName((j['auth'] as String?) ?? 'generatedKey'),
    keyId: j['keyId'] as String?,
    hostKeyFingerprint: j['hostKeyFingerprint'] as String?,
    transport: HostTransport.values.where((t) => t.name == j['transport']).firstOrNull ?? HostTransport.ssh,
    relay: j['relay'] is Map ? RelayHostInfo.fromJson((j['relay'] as Map).cast<String, Object?>()) : null,
  );
}

// ---------------------------------------------------------------------------
// Host capabilities (filled by provision/detect)
// ---------------------------------------------------------------------------

class ToolInfo {
  const ToolInfo(this.name, {this.installed = false, this.version, this.path});
  final String name; // agentd, zellij, tmux, node, npm, claude, codex, pando, opencode, gemini
  final bool installed;
  final String? version;
  final String? path;
}

class HostCapabilities {
  const HostCapabilities({
    this.os = '',
    this.arch = '',
    this.distro,
    this.systemdUser = false,
    this.runtimeDir,
    this.agentdSocket,
    this.tools = const {},
  });

  final String os; // Linux, Darwin
  final String arch; // x86_64, aarch64, arm64
  final String? distro;
  final bool systemdUser;
  final String? runtimeDir; // $XDG_RUNTIME_DIR
  final String? agentdSocket; // resolved daemon socket path, when agentd is there
  final Map<String, ToolInfo> tools;

  bool has(String tool) => tools[tool]?.installed ?? false;
}

// ---------------------------------------------------------------------------
// Sessions (agentd, zellij, tmux) as the UI sees them
// ---------------------------------------------------------------------------

/// Where a session runs. [shell] is a plain login shell over SSH started by
/// the app (terminal only; listed while its PTY is open).
enum SessionSource { agentd, zellij, tmux, shell }

enum AgentStatus { working, waiting, idle, starting, exited, unknown }

/// How a menu option is drawn by the TUI (agentd `ViewOption.kind`).
enum OptionKind { numbered, pointer, checkbox, yesno }

class SessionOption {
  const SessionOption({required this.id, required this.label, this.index, this.selected = false, this.kind, this.checked});
  final String id;
  final String label;
  final int? index; // number shown in the TUI menu, if any
  final bool selected;
  final OptionKind? kind;

  /// Checkbox state, only for [OptionKind.checkbox] options.
  final bool? checked;
}

/// What the agent is asking for.
enum PendingKind {
  /// Approve a tool call (run a command, edit a file...). [PendingInteraction.detail]
  /// carries the command / file when it could be read.
  permission,

  /// A question with options, or free text.
  question,

  /// Approve a plan before the agent starts coding.
  plan,
  unknown,
}

/// A question / permission dialog the agent is waiting on.
class PendingInteraction {
  const PendingInteraction({
    required this.question,
    this.options = const [],
    this.revision,
    this.epoch,
    this.kind = PendingKind.unknown,
    this.detail,
  });
  final String question;
  final List<SessionOption> options;
  final int? revision; // agentd view revision, required by act choose
  final String? epoch;
  final PendingKind kind;

  /// What the permission is about, e.g. the tool command (`npm run lint`).
  final String? detail;
}

class AgentSession {
  const AgentSession({
    required this.hostId,
    required this.source,
    required this.name,
    this.harness,
    this.project,
    this.status = AgentStatus.unknown,
    this.attention = false,
    this.preview,
    this.cwd,
    this.turn,
    this.updatedAt,
    this.pending,
    this.detail,
  });

  final String hostId;
  final SessionSource source;
  final String name; // agentd session name, zellij session, tmux session[:window]
  final String? harness; // claude, codex, pando...
  final String? project;
  final AgentStatus status;
  final bool attention;
  final String? preview; // last transcript line
  final String? cwd;
  final int? turn;
  final DateTime? updatedAt;
  final PendingInteraction? pending;
  final String? detail; // e.g. "3 panes"

  String get key => '$hostId/${source.name}/$name';
}

enum ChatRole { user, agent, tool, system }

/// Line that opens and closes a code block inside the text of an agent
/// [ChatItem]: what is between two of them is program text, shown as is.
const kChatCodeFence = '````';

class ChatItem {
  const ChatItem({required this.role, required this.text, this.title, this.ok, this.meta});
  final ChatRole role;

  /// user: the prompt. agent: chat markup, with code blocks between
  /// [kChatCodeFence] lines. tool: the call (its arguments, which may span
  /// several lines) followed by its output. system: a status note.
  final String text;
  final String? title; // tool name / command
  final bool? ok;

  /// Short summary shown next to a tool item (e.g. its first output line).
  final String? meta;
}

class SessionView {
  const SessionView({required this.session, this.items = const [], this.inputText = '', this.ghost, this.revision, this.epoch});
  final AgentSession session;
  final List<ChatItem> items;
  final String inputText;
  final String? ghost; // suggested prompt shown by the harness
  final int? revision;
  final String? epoch;
}

// ---------------------------------------------------------------------------
// Mailbox (agentd only)
// ---------------------------------------------------------------------------

enum MailState { queued, delivered, read, replied, unclaimed }

class MailMessage {
  const MailMessage({required this.id, required this.from, required this.to, required this.subject, required this.body, required this.state, required this.createdAt, this.replyTo, this.queue});
  final int id;
  final String from;
  final String to;
  final String subject;
  final String body;
  final MailState state;
  final DateTime createdAt;
  final int? replyTo;
  final String? queue;
}

class WorkQueue {
  const WorkQueue(this.name, this.unclaimed);
  final String name;
  final int unclaimed;
}

// ---------------------------------------------------------------------------
// Repositories consumed by the UI (implemented in lib/src/data, faked in
// lib/src/ui/fakes for previews and widget tests)
// ---------------------------------------------------------------------------

enum HostState { offline, connecting, online, error }

class HostStatus {
  const HostStatus(this.config, {this.state = HostState.offline, this.capabilities, this.error, this.sessionCount = 0});
  final HostConfig config;
  final HostState state;
  final HostCapabilities? capabilities;
  final String? error;
  final int sessionCount;
}

abstract class HostsRepository {
  Stream<List<HostStatus>> watch();
  Future<void> save(HostConfig config);
  Future<void> remove(String hostId);
  Future<void> connect(String hostId);

  /// Closes the connection of [hostId] and keeps it closed (no automatic
  /// reconnect) until [connect] or [reconnectAll].
  Future<void> disconnect(String hostId);

  /// [disconnect] for every saved host.
  Future<void> disconnectAll();

  /// Back in the foreground: checks the open connections (a cheap command
  /// with a short timeout; a dead one is dropped and reopened) and connects
  /// every other saved host at once, without waiting for the reconnect
  /// backoff. Hosts closed with [disconnect] are connected too.
  Future<void> reconnectAll();

  /// The open shell of [hostId], connecting when needed (provisioning,
  /// agentd socket, multiplexers).
  Future<RemoteShell> shell(String hostId);

  /// Generates (once) the app's ed25519 key and returns its OpenSSH public key line.
  Future<String> publicKey();

  /// Pairs this phone with a host through agentd-relay: [link] is the
  /// invite (`agentd://relay?...` from `agentd relay invite`), [deviceName]
  /// is shown on the host. [onPhase] reports progress (the host may wait for
  /// a human approval). Saves the host and returns its config. The invite
  /// code is never stored. Throws on a bad link, a refusal or a denial.
  Future<HostConfig> pairRelay(String link, {required String deviceName, void Function(RelayPairPhase phase)? onPhase});

  /// A new connection to the agentd daemon of a relay host (one stream of
  /// its tunnel, opened first when needed).
  Future<ByteChannel> agentdChannel(String hostId);

  /// Password bootstrap: connects once with [password], installs the app's
  /// public key in `~/.ssh/authorized_keys` (idempotent) and saves [config]
  /// as [AuthKind.generatedKey]. The password is never stored. Returns the
  /// saved config.
  Future<HostConfig> enrollWithPassword(HostConfig config, String password);
}

final _relayLinkStart = RegExp(r'agentd://relay\?', caseSensitive: false);
final _relayLinkBody = RegExp(r'^[A-Za-z0-9\-._~%+&=:/]*');
final _relayLinkLine = RegExp(r'\r\n|\n|\r');

/// The `agentd://relay?...` invite links that [text] may hold, best guess
/// first. [text] is what a person pasted or a camera scanned: the link may
/// have text around it (`Link:  agentd://...` copied from the terminal) and
/// may be cut by the terminal's line wraps. The first candidate joins the
/// following lines that hold nothing but link characters (a wrapped link);
/// the second one is the first line alone. Nothing is validated here: the
/// caller parses the candidates in order.
List<String> relayLinkCandidates(String text) {
  final m = _relayLinkStart.firstMatch(text);
  if (m == null) return const [];
  // A sentence's full stop is not part of the link.
  String link(String body) => 'agentd://relay?${body.replaceFirst(RegExp(r'\.+$'), '')}';
  final lines = text.substring(m.end).split(_relayLinkLine);
  final first = _relayLinkBody.stringMatch(lines.first) ?? '';
  final joined = StringBuffer(first);
  // The link runs to the end of its line: the next lines may continue it.
  if (first.length == lines.first.trimRight().length) {
    for (final l in lines.skip(1)) {
      final t = l.trim();
      if (t.isEmpty || _relayLinkBody.stringMatch(t) != t) break;
      joined.write(t);
    }
  }
  final a = link(joined.toString()), b = link(first);
  return [a, if (b != a) b];
}

/// Progress of [HostsRepository.pairRelay].
enum RelayPairPhase {
  /// Reaching the relay and running the handshake.
  connecting,

  /// The host accepted the invite and waits for its user to approve.
  waitingApproval,
}

/// A host key seen for the first time, waiting for the user's decision
/// (trust on first use). The UI answers with [reply].
class HostKeyPrompt {
  HostKeyPrompt({required this.host, required this.keyType, required this.fingerprint});
  final HostConfig host;
  final String keyType;
  final String fingerprint;
  final Completer<bool> _answer = Completer<bool>();

  Future<bool> get answer => _answer.future;
  bool get answered => _answer.isCompleted;

  void reply(bool trust) {
    if (!_answer.isCompleted) _answer.complete(trust);
  }
}

/// Channel between the SSH layer (asks) and the UI (shows a dialog).
/// Without a listener every new host key is refused.
class HostKeyPrompts {
  HostKeyPrompts({this.timeout = const Duration(minutes: 2)});
  final Duration timeout;
  final _c = StreamController<HostKeyPrompt>.broadcast();

  Stream<HostKeyPrompt> get stream => _c.stream;

  Future<bool> ask(HostConfig host, String keyType, String fingerprint) async {
    if (!_c.hasListener) return false;
    final p = HostKeyPrompt(host: host, keyType: keyType, fingerprint: fingerprint);
    _c.add(p);
    return p.answer.timeout(timeout, onTimeout: () {
      p.reply(false);
      return false;
    });
  }
}

/// Harness name of a terminal-only session (a login shell, no agent).
const kShellHarness = 'shell';

/// One folder of a host directory listing.
class DirEntry {
  const DirEntry(this.name, {this.enterable = true});
  final String name;

  /// False when the user can not read or traverse it (greyed in the browser).
  final bool enterable;
}

/// Directories inside [path] (absolute) on a host.
class DirListing {
  const DirListing({required this.path, required this.home, this.entries = const [], this.truncated = false});
  final String path;
  final String home;
  final List<DirEntry> entries; // sorted case-insensitively
  final bool truncated; // more folders than the listing cap
}

enum ListDirFailure { notFound, noPermission, other }

/// A directory that could not be listed (`No existe` / `Sin permiso`).
class ListDirException implements Exception {
  ListDirException(this.failure, this.path, [this.detail = '']);
  final ListDirFailure failure;
  final String path;
  final String detail;

  String get message => switch (failure) {
    ListDirFailure.notFound => 'No existe',
    ListDirFailure.noPermission => 'Sin permiso',
    ListDirFailure.other => 'No se pudo leer la carpeta',
  };

  @override
  String toString() => 'ListDirException(${failure.name}, $path)';
}

abstract class SessionsRepository {
  /// All sessions of every connected host, kept live.
  Stream<List<AgentSession>> watch();
  Stream<SessionView> view(AgentSession session);

  Future<void> prompt(AgentSession s, String text);
  Future<void> choose(AgentSession s, SessionOption option, {required int revision, required String epoch});
  Future<void> keys(AgentSession s, List<String> keys); // abstract names: enter esc tab up down ctrl-c ...
  Future<void> interrupt(AgentSession s);

  /// Copies an image to the host (private cache dir of the app, mode 0600) and
  /// returns its absolute remote path, to be written in a prompt. [extension]
  /// is without the dot (`png`, `jpg`).
  Future<String> uploadImage(
    AgentSession s,
    Uint8List bytes, {
    required String extension,
  });

  /// Raw terminal (agentd attach, zellij attach, tmux attach).
  Future<PtySession> terminal(AgentSession s, {int cols = 80, int rows = 24, bool observe = false});

  /// [harness] [kShellHarness] (or empty) opens a terminal only: the user's
  /// login shell in the project directory.
  Future<AgentSession> launch({required String hostId, required SessionSource where, required String project, required String harness, String? firstPrompt});

  /// Force-closes and deletes [s]: agentd = KILL, wait until exited, `rm`
  /// (an exited session only `rm`); zellij = kill + delete the session;
  /// tmux = kill-session; SSH shell = close the channel.
  Future<void> terminate(AgentSession s);

  /// Folders inside [path] on [hostId] (empty = the home directory), one
  /// shell script over the host. Throws [ListDirException].
  Future<DirListing> listDir(String hostId, String path, {bool hidden = false});

  /// Project names offered when launching: agentd aliases (op info). Empty
  /// when the host has no agentd.
  Future<List<String>> projects(String hostId);
}

abstract class MailRepository {
  Stream<List<MailMessage>> inbox(String hostId);
  Stream<List<WorkQueue>> queues(String hostId);
  Future<void> send(String hostId, {required String to, required String body, String subject = ''});
}

// ---------------------------------------------------------------------------
// Work dashboard (agentd only): what each agent is doing, has pending and
// asks the human. Agents write their tasks; the app only reads them.
// ---------------------------------------------------------------------------

enum TaskStatus { pending, inProgress, blocked, done, cancelled }

/// One item of an agent's plan. [title] and [note] are agent-written.
class AgentTask {
  const AgentTask({required this.id, required this.title, this.status = TaskStatus.pending, this.note, this.updatedAt, this.fromBacklog = false});
  final String id;
  final String title;
  final TaskStatus status;
  final String? note;
  final DateTime? updatedAt;

  /// The human assigned it from the backlog (a [BacklogNote]).
  final bool fromBacklog;
}

enum NoteState { open, assigned, done }

/// A backlog note: something the human wrote down on a host to hand to an
/// agent later. Assigned, it is task [taskId] of session [assignedTo]; it
/// becomes done when the agent finishes that task.
class BacklogNote {
  const BacklogNote({required this.id, required this.title, this.body = '', this.state = NoteState.open, this.assignedTo, this.taskId, this.createdAt, this.updatedAt, this.assignedAt, this.doneAt});
  final int id;
  final String title;
  final String body;
  final NoteState state;
  final String? assignedTo;
  final String? taskId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? assignedAt;
  final DateTime? doneAt;

  /// Limits the daemon enforces (runes).
  static const maxTitle = 200;
  static const maxBody = 4000;
}

/// Why a backlog change was refused.
enum BacklogFailure {
  /// The daemon refused the values (blank or too long title, a note that is
  /// done, a session whose task list is full).
  invalid,

  /// The note (or the session) no longer exists.
  notFound,

  /// The session is not running (exited or still starting).
  sessionNotRunning,

  /// This device may not use the backlog.
  forbidden,

  /// The host has no backlog (older agentd, store unavailable, offline).
  unavailable,
}

class BacklogException implements Exception {
  const BacklogException(this.failure, [this.message = '']);
  final BacklogFailure failure;

  /// The daemon's own words (English), for logs.
  final String message;

  @override
  String toString() => 'BacklogException(${failure.name}): $message';
}

/// A question an agent asked the human through the mailbox, still open.
/// Answering it is a mailbox reply to [id].
class AgentQuestion {
  const AgentQuestion({required this.id, required this.body, this.options = const [], this.taskId, this.createdAt});
  final int id;
  final String body;
  final List<String> options;

  /// The asking agent's task this question is about (not checked by the daemon).
  final String? taskId;
  final DateTime? createdAt;
}

/// One agentd session on the board.
class BoardSession {
  const BoardSession({
    required this.hostId,
    required this.name,
    this.status = AgentStatus.unknown,
    this.attention = false,
    this.turn,
    this.preview,
    this.tasks = const [],
    this.questions = const [],
  });
  final String hostId;
  final String name;
  final AgentStatus status;
  final bool attention;
  final int? turn;
  final String? preview;
  final List<AgentTask> tasks;
  final List<AgentQuestion> questions;

  /// Same as [AgentSession.key] of the session.
  String get key => '$hostId/${SessionSource.agentd.name}/$name';

  int count(TaskStatus s) => tasks.where((t) => t.status == s).length;

  /// Tasks that count for progress (cancelled ones do not).
  int get total => tasks.length - count(TaskStatus.cancelled);
  int get done => count(TaskStatus.done);

  /// The first task in progress.
  AgentTask? get current => tasks.where((t) => t.status == TaskStatus.inProgress).firstOrNull;
}

/// The board of one host. [available] is false while the host has no
/// reachable agentd or its daemon has no board (older than the dashboard).
class HostBoard {
  const HostBoard({required this.hostId, this.sessions = const [], this.unreadHuman = 0, this.available = true, this.notes = const [], this.backlog = false});
  final String hostId;
  final List<BoardSession> sessions;

  /// Unread messages of the user's mailbox.
  final int unreadHuman;
  final bool available;

  /// The host's backlog: open notes first, then assigned, then done.
  final List<BacklogNote> notes;

  /// Whether the host has a backlog this device may use (false: an agentd
  /// older than the backlog, a relay device without the right, no store).
  /// The UI hides the section then.
  final bool backlog;

  HostBoard withBacklog(List<BacklogNote>? notes) =>
      HostBoard(hostId: hostId, sessions: sessions, unreadHuman: unreadHuman, available: available, notes: notes ?? const [], backlog: notes != null);
}

abstract class BoardRepository {
  /// The board of [hostId], kept live while listened to.
  Stream<HostBoard> watch(String hostId);

  /// Answers question [questionId] (a mailbox reply; it closes the question).
  /// With [notify] false the reply is only recorded, not delivered to the
  /// agent: for an answer already typed in its prompt.
  Future<void> answer(String hostId, int questionId, String body, {bool notify = true});

  // Backlog notes. Every change throws [BacklogException] when refused; the
  // board of [watch] follows.

  /// Adds an open note.
  Future<BacklogNote> addNote(String hostId, {required String title, String body = ''});

  /// Edits a note: null fields are unchanged. [reopen] takes an assigned or
  /// done note back into the backlog (the agent's task is left alone).
  Future<BacklogNote> updateNote(String hostId, int noteId, {String? title, String? body, bool reopen = false});

  Future<void> removeNote(String hostId, int noteId);

  /// Hands a note to the running session [session] of the same host as a
  /// pending task, or one in progress with [inProgress]; the agent is told
  /// through its mailbox. Returns a warning when the note was assigned but
  /// the notice could not be sent.
  Future<String?> assignNote(String hostId, int noteId, {required String session, bool inProgress = false});
}

// ---------------------------------------------------------------------------
// Devices paired with a host through agentd-relay (phones, desktops).
// ---------------------------------------------------------------------------

/// A device that may reach the host through its relay.
class PairedDevice {
  const PairedDevice({
    required this.id,
    this.name = '',
    this.platform = '',
    this.scope = RelayScope.view,
    this.sessions = const [],
    this.guest = false,
    this.createdAt,
    this.expiresAt,
    this.lastSeen,
    this.online = false,
    this.isThisDevice = false,
  });
  final String id;
  final String name;

  /// android | ios | linux | macos | windows ('' when unknown).
  final String platform;
  final RelayScope scope;

  /// Session name globs the device is limited to (empty = all).
  final List<String> sessions;
  final bool guest;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final DateTime? lastSeen;

  /// Connected to the host right now.
  final bool online;

  /// The device is this app (relay hosts only).
  final bool isThisDevice;
}

enum DevicesFailure {
  /// This device may not do that (list, or revoke another device).
  forbidden,

  /// The device is not paired any more.
  notFound,

  /// The host is offline, has no agentd or its agentd is too old.
  unavailable,
}

class DevicesException implements Exception {
  const DevicesException(this.failure, [this.message = '']);
  final DevicesFailure failure;
  final String message;

  @override
  String toString() => 'DevicesException(${failure.name}): $message';
}

abstract class DevicesRepository {
  /// The devices paired with [hostId]. Over SSH, and for a relay device that
  /// [HostConfig.canManageDevices], all of them; otherwise only this device.
  /// Throws [DevicesException].
  Future<List<PairedDevice>> devices(String hostId);

  /// Revokes [deviceId]: it can not connect again until it is paired with a
  /// new invite. Revoking this device ([PairedDevice.isThisDevice]) also
  /// removes the host from the app, since it is unreachable from then on.
  /// Throws [DevicesException].
  Future<void> revoke(String hostId, String deviceId);
}

/// What a tapped push notification points at (FCM data of the daemon's
/// `[push]` tap, agentd 0.10.0 or later).
class PushOpen {
  const PushOpen({required this.hostId, required this.session, required this.reason, this.messageId});

  /// The saved host id the app gave at `push_register` (`host_ref`).
  final String hostId;
  final String session;

  /// `question`, `permission`, or one of the optional reasons (`waiting`,
  /// `blocked`, `exited`, `turn_done`).
  final String reason;
  final int? messageId;

  /// Reads the notification data; null when it is not an agentd push.
  static PushOpen? fromData(Map<String, Object?> data) {
    final host = data['host_ref'];
    final session = data['session'];
    if (data['v'] != '1' || host is! String || host.isEmpty || session is! String) return null;
    final reason = data['reason'];
    final id = data['message_id'];
    return PushOpen(hostId: host, session: session, reason: reason is String ? reason : '', messageId: id is String ? int.tryParse(id) : (id is int ? id : null));
  }

  /// The session's key in the app ([AgentSession.key]).
  String get sessionKey => '$hostId/${SessionSource.agentd.name}/$session';

  @override
  bool operator ==(Object other) => other is PushOpen && other.hostId == hostId && other.session == session && other.reason == reason && other.messageId == messageId;

  @override
  int get hashCode => Object.hash(hostId, session, reason, messageId);
}

/// Push registrations of this device on the hosts' daemons (ops
/// `push_register` / `push_unregister`).
abstract class PushRepository {
  /// Registers [token] on [hostId] under [deviceName]; the daemon's push
  /// data carries [hostId] back as `host_ref`. False when the host cannot
  /// take it (offline, no agentd, a daemon without the op, not allowed):
  /// never throws.
  Future<bool> register(String hostId, {required String token, required String deviceName});

  /// Removes [token] from [hostId]; best effort, never throws.
  Future<void> unregister(String hostId, {required String token});
}

enum ProvisionStep { download, verify, install, service, hcListener, mcp, cli }

class ProvisionEvent {
  const ProvisionEvent(this.step, this.message, {this.done = false, this.error, this.skipped = false});
  final ProvisionStep step;
  final String message;
  final bool done;
  final String? error;

  /// The step did not run because a step it needs failed.
  final bool skipped;
}

/// One step of an install plan.
class PlannedStep {
  const PlannedStep({required this.step, required this.title, required this.command, required this.group, this.needs = const {}, this.timeout = const Duration(minutes: 5)});

  final ProvisionStep step;
  final String title;

  /// The exact script run through the remote login shell.
  final String command;

  /// Steps of one group stop at the first failure (download → verify →
  /// install of agentd).
  final String group;

  /// Groups that must not have failed for this step to run.
  final Set<String> needs;
  final Duration timeout;
}

abstract class ProvisionService {
  Future<HostCapabilities> detect(RemoteShell shell);

  /// Shell commands that [install] would run, shown to the user first.
  List<String> plan(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}});

  /// The same plan with a title per step.
  List<PlannedStep> planSteps(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}});

  Stream<ProvisionEvent> install(RemoteShell shell, HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}});
}
