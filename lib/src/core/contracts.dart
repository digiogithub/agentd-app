// Shared contracts between the app layers. Every layer codes against these
// types; implementations live in their own folders:
//
//   lib/src/transport/  SSH (RemoteShell, HostKeyStore, KeyStore)
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
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String user;
  final AuthKind auth;
  final String? keyId;

  /// SHA256 fingerprint accepted on first connect (trust on first use).
  final String? hostKeyFingerprint;

  HostConfig copyWith({String? name, String? host, int? port, String? user, AuthKind? auth, String? keyId, String? hostKeyFingerprint}) =>
      HostConfig(
        id: id,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        user: user ?? this.user,
        auth: auth ?? this.auth,
        keyId: keyId ?? this.keyId,
        hostKeyFingerprint: hostKeyFingerprint ?? this.hostKeyFingerprint,
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

class ChatItem {
  const ChatItem({required this.role, required this.text, this.title, this.ok, this.meta});
  final ChatRole role;
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

  /// The open shell of [hostId], connecting when needed (provisioning,
  /// agentd socket, multiplexers).
  Future<RemoteShell> shell(String hostId);

  /// Generates (once) the app's ed25519 key and returns its OpenSSH public key line.
  Future<String> publicKey();

  /// Password bootstrap: connects once with [password], installs the app's
  /// public key in `~/.ssh/authorized_keys` (idempotent) and saves [config]
  /// as [AuthKind.generatedKey]. The password is never stored. Returns the
  /// saved config.
  Future<HostConfig> enrollWithPassword(HostConfig config, String password);
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

  Future<AgentSession> launch({required String hostId, required SessionSource where, required String project, required String harness, String? firstPrompt});

  /// Project names offered when launching: agentd aliases (op info). Empty
  /// when the host has no agentd.
  Future<List<String>> projects(String hostId);
}

abstract class MailRepository {
  Stream<List<MailMessage>> inbox(String hostId);
  Stream<List<WorkQueue>> queues(String hostId);
  Future<void> send(String hostId, {required String to, required String body, String subject = ''});
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
