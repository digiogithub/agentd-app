// Typed mirrors of the agentd wire structs (agentd `internal/proto`). Field
// names in fromJson are the daemon's JSON names; absent fields (Go
// `omitempty`) get neutral defaults.

typedef Json = Map<String, Object?>;

Json _map(Object? v) => v is Map ? v.cast<String, Object?>() : const {};
List<Object?> _list(Object? v) => v is List ? v : const [];
String _str(Object? v) => v is String ? v : '';
String? _strOrNull(Object? v) => v is String && v.isNotEmpty ? v : null;
int _int(Object? v) => v is num ? v.toInt() : 0;
int? _intOrNull(Object? v) => v is num ? v.toInt() : null;
bool _bool(Object? v) => v == true;
double _double(Object? v) => v is num ? v.toDouble() : 0;
Map<String, String> _strMap(Object? v) =>
    v is Map ? {for (final e in v.entries) '${e.key}': e.value is String ? e.value as String : '${e.value}'} : const {};

/// Parses a Go `time.Time` (RFC 3339, nanoseconds allowed). The zero time
/// (`0001-01-01T00:00:00Z`) and anything unparsable are null.
DateTime? parseGoTime(Object? v) {
  if (v is! String || v.isEmpty || v.startsWith('0001-01-01')) return null;
  return DateTime.tryParse(v);
}

/// Answer of `ping`.
/// Answer of `push_register`. [mode] (effective delivery: `notification` or
/// `data`) and [modes] (what the daemon accepts) come from agentd with the
/// Android data mode; older daemons send only [id].
class AgentdPushRegistration {
  const AgentdPushRegistration({required this.id, this.mode, this.modes = const []});
  final String id;
  final String? mode;
  final List<String> modes;

  factory AgentdPushRegistration.fromJson(Map<String, dynamic> j) => AgentdPushRegistration(
        id: j['id'] is String ? j['id'] as String : '',
        mode: j['mode'] is String ? j['mode'] as String : null,
        modes: j['modes'] is List ? [for (final m in j['modes'] as List) if (m is String) m] : const [],
      );
}

class AgentdPing {
  const AgentdPing({required this.version, required this.pid, required this.epoch});
  factory AgentdPing.fromJson(Json j) => AgentdPing(version: _str(j['version']), pid: _int(j['pid']), epoch: _str(j['epoch']));
  final String version;
  final int pid;
  final String epoch;
}

class AgentdProfile {
  const AgentdProfile({required this.name, this.builtin = false, this.cols = 0, this.rows = 0});
  factory AgentdProfile.fromJson(Json j) =>
      AgentdProfile(name: _str(j['name']), builtin: _bool(j['builtin']), cols: _int(j['cols']), rows: _int(j['rows']));
  final String name;
  final bool builtin;
  final int cols;
  final int rows;
}

class AgentdAlias {
  const AgentdAlias({required this.name, required this.dir, required this.source});
  factory AgentdAlias.fromJson(Json j) => AgentdAlias(name: _str(j['name']), dir: _str(j['dir']), source: _str(j['source']));
  final String name;
  final String dir;
  final String source; // file | env
}

/// Answer of `info`.
class AgentdInfo {
  const AgentdInfo({
    required this.host,
    required this.version,
    required this.pid,
    required this.epoch,
    this.harnesses = const [],
    this.profiles = const [],
    this.aliases = const [],
    this.agentView = false,
  });
  factory AgentdInfo.fromJson(Json j) => AgentdInfo(
    host: _str(j['host']),
    version: _str(j['version']),
    pid: _int(j['pid']),
    epoch: _str(j['epoch']),
    harnesses: [for (final h in _list(j['harnesses'])) _str(h)],
    profiles: [for (final p in _list(j['profiles'])) AgentdProfile.fromJson(_map(p))],
    aliases: [for (final a in _list(j['aliases'])) AgentdAlias.fromJson(_map(a))],
    agentView: _bool(j['agent_view']),
  );
  final String host;
  final String version;
  final int pid;
  final String epoch;
  final List<String> harnesses;
  final List<AgentdProfile> profiles;
  final List<AgentdAlias> aliases;
  final bool agentView;
}

/// One OSC 7501 program status record.
class AgentdProgramStatus {
  const AgentdProgramStatus({required this.state, this.kind, this.progress, this.app, this.title, this.msg});
  factory AgentdProgramStatus.fromJson(Json j) => AgentdProgramStatus(
    state: _str(j['state']),
    kind: _strOrNull(j['kind']),
    progress: _intOrNull(j['progress']),
    app: _strOrNull(j['app']),
    title: _strOrNull(j['title']),
    msg: _strOrNull(j['msg']),
  );
  final String state;
  final String? kind;
  final int? progress;
  final String? app;
  final String? title;
  final String? msg;
}

/// `SessionInfo`: element of `ls`, answer of `run`, data of
/// `session.created` / `session.started`, snapshot of `subscribe`.
class AgentdSessionInfo {
  const AgentdSessionInfo({
    required this.name,
    this.state = '',
    this.pid = 0,
    this.cwd = '',
    this.cmd = const [],
    this.profile = '',
    this.exitCode,
    this.startedAt,
    this.lastOutput,
    this.idleMs = 0,
    this.unread = 0,
    this.attached = 0,
    this.cols = 0,
    this.rows = 0,
    this.title,
    this.inputState,
    this.status,
    this.attention = false,
    this.revision = 0,
    this.preview,
    this.turn = 0,
    this.labels = const {},
    this.programStatus,
    this.reported = false,
    this.tasks,
  });

  factory AgentdSessionInfo.fromJson(Json j) => AgentdSessionInfo(
    name: _str(j['name']),
    state: _str(j['state']),
    pid: _int(j['pid']),
    cwd: _str(j['cwd']),
    cmd: [for (final c in _list(j['cmd'])) _str(c)],
    profile: _str(j['profile']),
    exitCode: _intOrNull(j['exit_code']),
    startedAt: parseGoTime(j['started_at']),
    lastOutput: parseGoTime(j['last_output']),
    idleMs: _int(j['idle_ms']),
    unread: _int(j['unread']),
    attached: _int(j['attached']),
    cols: _int(j['cols']),
    rows: _int(j['rows']),
    title: _strOrNull(j['title']),
    inputState: _strOrNull(j['input_state']),
    status: _strOrNull(j['status']),
    attention: _bool(j['attention']),
    revision: _int(j['revision']),
    preview: _strOrNull(j['preview']),
    turn: _int(j['turn']),
    labels: _strMap(j['labels']),
    programStatus: j['program_status'] is Map ? AgentdProgramStatus.fromJson(_map(j['program_status'])) : null,
    reported: _bool(j['reported']),
    tasks: j['tasks'] is Map ? AgentdTaskSummary.fromJson(_map(j['tasks'])) : null,
  );

  final String name;

  /// Process state: starting | running | exited.
  final String state;
  final int pid;
  final String cwd;
  final List<String> cmd;
  final String profile;
  final int? exitCode;
  final DateTime? startedAt;
  final DateTime? lastOutput;
  final int idleMs;
  final int unread;
  final int attached;
  final int cols;
  final int rows;
  final String? title;

  /// empty | draft | suggestion (null for exited sessions).
  final String? inputState;

  /// Semantic status: starting | working | idle | waiting | exited (null
  /// while starting, from the cached view).
  final String? status;
  final bool attention;
  final int revision;
  final String? preview;
  final int turn;
  final Map<String, String> labels;
  final AgentdProgramStatus? programStatus;
  final bool reported;

  /// Summary of the session's task list (null until it reports one).
  final AgentdTaskSummary? tasks;
}

class AgentdAttention {
  const AgentdAttention({this.set = false, this.reason, this.since});
  factory AgentdAttention.fromJson(Json j) =>
      AgentdAttention(set: _bool(j['set']), reason: _strOrNull(j['reason']), since: parseGoTime(j['since']));
  final bool set;
  final String? reason; // turn_done | waiting | bell | notify
  final DateTime? since;
}

class AgentdViewLine {
  const AgentdViewLine(this.text, this.role, {this.md = '', this.code = false});
  factory AgentdViewLine.fromJson(Json j) => AgentdViewLine(_str(j['text']), _str(j['role']), md: _str(j['md']), code: j['code'] == true);
  final String text;

  /// The line is syntax-highlighted program text (view `markup: true`,
  /// agentd 0.8.2 or later; older daemons never send it). It has no [md].
  final bool code;

  /// Chat markup of the line (view `markup: true`): CommonMark built from
  /// the terminal styles; empty when it equals [text].
  final String md;

  /// [md], or [text] when the line has none.
  String get markup => md.isNotEmpty ? md : text;

  /// transcript | status | dialog | gap
  final String role;
}

class AgentdViewInput {
  const AgentdViewInput({this.text = '', this.ghost = '', this.state = ''});
  factory AgentdViewInput.fromJson(Json j) => AgentdViewInput(text: _str(j['text']), ghost: _str(j['ghost']), state: _str(j['state']));
  final String text;
  final String ghost;
  final String state; // empty | suggestion | draft
}

class AgentdViewOption {
  const AgentdViewOption({
    required this.id,
    required this.label,
    this.index = 0,
    this.kind = '',
    this.selected = false,
    this.checked,
    this.confidence = 0,
  });
  factory AgentdViewOption.fromJson(Json j) => AgentdViewOption(
    id: _str(j['id']),
    label: _str(j['label']),
    index: _int(j['index']),
    kind: _str(j['kind']),
    selected: _bool(j['selected']),
    checked: j['checked'] is bool ? j['checked'] as bool : null,
    confidence: _double(j['confidence']),
  );
  final String id;
  final String label;
  final int index;
  final String kind; // numbered | pointer | checkbox | yesno
  final bool selected;
  final bool? checked;
  final double confidence;
}

class AgentdViewHint {
  const AgentdViewHint(this.key, this.action);
  factory AgentdViewHint.fromJson(Json j) => AgentdViewHint(_str(j['key']), _str(j['action']));
  final String key;
  final String action;
}

/// Answer of `view` (the semantic View). When [notModified] is true only
/// [name], [epoch] and [revision] are meaningful.
class AgentdView {
  const AgentdView({
    required this.name,
    this.notModified = false,
    this.epoch = '',
    this.revision = 0,
    this.status = '',
    this.statusReason,
    this.attention = const AgentdAttention(),
    this.title,
    this.cwd,
    this.firstLine = 0,
    this.lines = const [],
    this.input = const AgentdViewInput(),
    this.options = const [],
    this.hints = const [],
    this.dialogQuestion,
    this.idleMs = 0,
    this.exitCode,
  });

  factory AgentdView.fromJson(Json j, {String? name}) => AgentdView(
    name: _str(j['name']).isEmpty ? (name ?? '') : _str(j['name']),
    notModified: _bool(j['not_modified']),
    epoch: _str(j['epoch']),
    revision: _int(j['revision']),
    status: _str(j['status']),
    statusReason: _strOrNull(j['status_reason']),
    attention: AgentdAttention.fromJson(_map(j['attention'])),
    title: _strOrNull(j['title']),
    cwd: _strOrNull(j['cwd']),
    firstLine: _int(j['first_line']),
    lines: [for (final l in _list(j['lines'])) AgentdViewLine.fromJson(_map(l))],
    input: AgentdViewInput.fromJson(_map(j['input'])),
    options: [for (final o in _list(j['options'])) AgentdViewOption.fromJson(_map(o))],
    hints: [for (final h in _list(j['hints'])) AgentdViewHint.fromJson(_map(h))],
    dialogQuestion: j['dialog'] is Map ? _str(_map(j['dialog'])['question']) : null,
    idleMs: _int(j['idle_ms']),
    exitCode: _intOrNull(j['exit_code']),
  );

  final String name;
  final bool notModified;
  final String epoch;
  final int revision;
  final String status;
  final String? statusReason;
  final AgentdAttention attention;
  final String? title;
  final String? cwd;
  final int firstLine;
  final List<AgentdViewLine> lines;
  final AgentdViewInput input;
  final List<AgentdViewOption> options;
  final List<AgentdViewHint> hints;

  /// `dialog.question` when a dialog is on screen (may be "").
  final String? dialogQuestion;
  final int idleMs;
  final int? exitCode;
}

/// Answer of `act`.
class AgentdActResult {
  const AgentdActResult({this.revision = 0, this.status = '', this.result = '', this.submitted = false, this.warning});
  factory AgentdActResult.fromJson(Json j) => AgentdActResult(
    revision: _int(j['revision']),
    status: _str(j['status']),
    result: _str(j['result']),
    submitted: _bool(j['submitted']),
    warning: _strOrNull(j['warning']),
  );
  final int revision;
  final String status;

  /// submitted | pasted | selected | keys_sent | interrupted | cancelled
  final String result;
  final bool submitted;
  final String? warning;
}

/// A mailbox message (`proto.Message`).
class AgentdMessage {
  const AgentdMessage({
    required this.id,
    this.sender = '',
    this.recipient = '',
    this.subject = '',
    this.body = '',
    this.replyTo,
    this.state = '',
    this.attempts = 0,
    this.createdAt,
    this.deliveredAt,
    this.readAt,
    this.repliedAt,
    this.queue,
    this.claimedAt,
    this.warning,
    this.kind = '',
    this.options = const [],
    this.task,
  });
  factory AgentdMessage.fromJson(Json j) => AgentdMessage(
    id: _int(j['id']),
    sender: _str(j['sender']),
    recipient: _str(j['recipient']),
    subject: _str(j['subject']),
    body: _str(j['body']),
    replyTo: _intOrNull(j['reply_to']),
    state: _str(j['state']),
    attempts: _int(j['attempts']),
    createdAt: parseGoTime(j['created_at']),
    deliveredAt: parseGoTime(j['delivered_at']),
    readAt: parseGoTime(j['read_at']),
    repliedAt: parseGoTime(j['replied_at']),
    queue: _strOrNull(j['queue']),
    claimedAt: parseGoTime(j['claimed_at']),
    warning: _strOrNull(j['warning']),
    kind: _str(j['kind']),
    options: [for (final o in _list(j['options'])) _str(o)],
    task: _strOrNull(j['task']),
  );
  final int id;
  final String sender;
  final String recipient;
  final String subject;
  final String body;
  final int? replyTo;

  /// queued | delivered | read | replied | unclaimed
  final String state;
  final int attempts;
  final DateTime? createdAt;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final DateTime? repliedAt;
  final String? queue;
  final DateTime? claimedAt;
  final String? warning;

  /// '' | question (a session asking the human).
  final String kind;

  /// Answer options of a question (at most 8).
  final List<String> options;

  /// Task id of the sender the question is about.
  final String? task;

  bool get isQuestion => kind == 'question';
}

/// Answer of `inbox`.
class AgentdInbox {
  const AgentdInbox({this.messages = const [], this.digest, this.notModified = false});
  factory AgentdInbox.fromJson(Json j) => AgentdInbox(
    messages: [for (final m in _list(j['messages'])) AgentdMessage.fromJson(_map(m))],
    digest: _strOrNull(j['digest']),
    notModified: _bool(j['not_modified']),
  );
  final List<AgentdMessage> messages;
  final String? digest;
  final bool notModified;
}

class AgentdQueueCount {
  const AgentdQueueCount(this.name, this.unclaimed);
  factory AgentdQueueCount.fromJson(Json j) => AgentdQueueCount(_str(j['name']), _int(j['unclaimed']));
  final String name;
  final int unclaimed;
}

/// Answer of `queue`: [items] for a named queue, [queues] for the listing.
class AgentdQueueResult {
  const AgentdQueueResult({this.name, this.items = const [], this.queues = const [], this.digest, this.notModified = false});
  factory AgentdQueueResult.fromJson(Json j) => AgentdQueueResult(
    name: _strOrNull(j['name']),
    items: [for (final m in _list(j['items'])) AgentdMessage.fromJson(_map(m))],
    queues: [for (final q in _list(j['queues'])) AgentdQueueCount.fromJson(_map(q))],
    digest: _strOrNull(j['digest']),
    notModified: _bool(j['not_modified']),
  );
  final String? name;
  final List<AgentdMessage> items;
  final List<AgentdQueueCount> queues;
  final String? digest;
  final bool notModified;
}

/// One item of a session's plan (`proto.Task`). Agent-written text.
class AgentdTask {
  const AgentdTask({required this.id, required this.title, this.status = 'pending', this.note, this.updatedAt, this.origin});
  factory AgentdTask.fromJson(Json j) => AgentdTask(
    id: _str(j['id']),
    title: _str(j['title']),
    status: _strOrNull(j['status']) ?? 'pending',
    note: _strOrNull(j['note']),
    updatedAt: parseGoTime(j['updated_at']),
    origin: _strOrNull(j['origin']),
  );

  /// [origin] of a task the human assigned from the backlog.
  static const originBacklog = 'backlog';

  /// `backlog` for a task that came from a backlog note; null otherwise.
  final String? origin;
  final String id;
  final String title;

  /// pending | in_progress | blocked | done | cancelled
  final String status;
  final String? note;
  final DateTime? updatedAt;
}

/// Tasks per status (`proto.TaskCounts`).
class AgentdTaskCounts {
  const AgentdTaskCounts({this.pending = 0, this.inProgress = 0, this.blocked = 0, this.done = 0, this.cancelled = 0});
  factory AgentdTaskCounts.fromJson(Json j) => AgentdTaskCounts(
    pending: _int(j['pending']),
    inProgress: _int(j['in_progress']),
    blocked: _int(j['blocked']),
    done: _int(j['done']),
    cancelled: _int(j['cancelled']),
  );
  final int pending;
  final int inProgress;
  final int blocked;
  final int done;
  final int cancelled;
}

/// `SessionInfo.tasks`: revision, counts and the first in_progress title.
class AgentdTaskSummary {
  const AgentdTaskSummary({this.revision = 0, this.counts = const AgentdTaskCounts(), this.current});
  factory AgentdTaskSummary.fromJson(Json j) => AgentdTaskSummary(
    revision: _int(j['revision']),
    counts: AgentdTaskCounts.fromJson(_map(j['counts'])),
    current: _strOrNull(j['current']),
  );
  final int revision;
  final AgentdTaskCounts counts;
  final String? current;
}

/// Answer of `tasks` (and of the session-only `tasks_set` / `task_update`).
class AgentdTasksResult {
  const AgentdTasksResult({this.name, this.tasks = const [], this.revision = 0});
  factory AgentdTasksResult.fromJson(Json j) => AgentdTasksResult(
    name: _strOrNull(j['name']),
    tasks: [for (final t in _list(j['tasks'])) AgentdTask.fromJson(_map(t))],
    revision: _int(j['revision']),
  );
  final String? name;
  final List<AgentdTask> tasks;
  final int revision;
}

/// One task a revision added or changed (`proto.TaskChange`).
class AgentdTaskChange {
  const AgentdTaskChange({required this.id, this.title = '', this.status = '', this.from});
  factory AgentdTaskChange.fromJson(Json j) =>
      AgentdTaskChange(id: _str(j['id']), title: _str(j['title']), status: _str(j['status']), from: _strOrNull(j['from']));
  final String id;
  final String title;
  final String status;

  /// Previous status (null for a new task or an unchanged status).
  final String? from;
}

/// A question a session asked the human and nobody answered (`proto.BoardQuestion`).
class AgentdBoardQuestion {
  const AgentdBoardQuestion({required this.id, this.body = '', this.options = const [], this.task, this.createdAt});
  factory AgentdBoardQuestion.fromJson(Json j) => AgentdBoardQuestion(
    id: _int(j['id']),
    body: _str(j['body']),
    options: [for (final o in _list(j['options'])) _str(o)],
    task: _strOrNull(j['task']),
    createdAt: parseGoTime(j['created_at']),
  );
  final int id;
  final String body;
  final List<String> options;
  final String? task;
  final DateTime? createdAt;
}

/// One session of the board (`proto.BoardSession`).
class AgentdBoardSession {
  const AgentdBoardSession({
    required this.name,
    this.status = '',
    this.attention = false,
    this.turn = 0,
    this.preview,
    this.tasks = const [],
    this.questions = const [],
  });
  factory AgentdBoardSession.fromJson(Json j) => AgentdBoardSession(
    name: _str(j['name']),
    status: _str(j['status']),
    attention: _bool(j['attention']),
    turn: _int(j['turn']),
    preview: _strOrNull(j['preview']),
    tasks: [for (final t in _list(j['tasks'])) AgentdTask.fromJson(_map(t))],
    questions: [for (final q in _list(j['questions'])) AgentdBoardQuestion.fromJson(_map(q))],
  );
  final String name;
  final String status;
  final bool attention;
  final int turn;
  final String? preview;
  final List<AgentdTask> tasks;
  final List<AgentdBoardQuestion> questions;
}

/// Answer of `board`. With `since_digest` still current: [notModified] and
/// only the digest.
class AgentdBoard {
  const AgentdBoard({this.sessions = const [], this.unreadHuman = 0, this.digest = '', this.notModified = false});
  factory AgentdBoard.fromJson(Json j) => AgentdBoard(
    sessions: [for (final s in _list(j['sessions'])) AgentdBoardSession.fromJson(_map(s))],
    unreadHuman: _int(j['unread_human']),
    digest: _str(j['digest']),
    notModified: _bool(j['not_modified']),
  );
  final List<AgentdBoardSession> sessions;
  final int unreadHuman;
  final String digest;
  final bool notModified;
}

/// One backlog note (`proto.Note`): something the human wrote down on the
/// host to assign to a session later.
class AgentdNote {
  const AgentdNote({required this.id, this.title = '', this.body = '', this.state = 'open', this.assignedTo, this.taskId, this.createdAt, this.updatedAt, this.assignedAt, this.doneAt});
  factory AgentdNote.fromJson(Json j) => AgentdNote(
    id: _int(j['id']),
    title: _str(j['title']),
    body: _str(j['body']),
    state: _strOrNull(j['state']) ?? 'open',
    assignedTo: _strOrNull(j['assigned_to']),
    taskId: _strOrNull(j['task_id']),
    createdAt: parseGoTime(j['created_at']),
    updatedAt: parseGoTime(j['updated_at']),
    assignedAt: parseGoTime(j['assigned_at']),
    doneAt: parseGoTime(j['done_at']),
  );
  final int id;
  final String title;
  final String body;

  /// open | assigned | done
  final String state;
  final String? assignedTo;
  final String? taskId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? assignedAt;
  final DateTime? doneAt;
}

/// Answer of `notes`. With `since_digest` still current: [notModified] and
/// only the digest.
class AgentdNotesResult {
  const AgentdNotesResult({this.notes = const [], this.digest = '', this.notModified = false});
  factory AgentdNotesResult.fromJson(Json j) => AgentdNotesResult(
    notes: [for (final n in _list(j['notes'])) AgentdNote.fromJson(_map(n))],
    digest: _str(j['digest']),
    notModified: _bool(j['not_modified']),
  );
  final List<AgentdNote> notes;
  final String digest;
  final bool notModified;
}

/// Answer of `note_assign`: the note, the task created in the session and
/// the notice sent to it. [warning] is set when the notice failed (the
/// assignment stands).
class AgentdNoteAssignResult {
  const AgentdNoteAssignResult({required this.note, required this.task, this.messageId, this.warning});
  factory AgentdNoteAssignResult.fromJson(Json j) => AgentdNoteAssignResult(
    note: AgentdNote.fromJson(_map(j['note'])),
    task: AgentdTask.fromJson(_map(j['task'])),
    messageId: j['message_id'] == null ? null : _int(j['message_id']),
    warning: _strOrNull(j['warning']),
  );
  final AgentdNote note;
  final AgentdTask task;
  final int? messageId;
  final String? warning;
}

/// A device paired through the relay (`proto.RelayDeviceInfo`).
class AgentdRelayDevice {
  const AgentdRelayDevice({required this.id, this.name = '', this.platform = '', this.scope = '', this.sessions = const [], this.kind = '', this.createdAt, this.expiresAt, this.lastSeen, this.online = false});
  factory AgentdRelayDevice.fromJson(Json j) => AgentdRelayDevice(
    id: _str(j['id']),
    name: _str(j['name']),
    platform: _str(j['platform']),
    scope: _str(j['scope']),
    sessions: [for (final s in _list(j['sessions'])) _str(s)],
    kind: _str(j['kind']),
    createdAt: parseGoTime(j['created_at']),
    expiresAt: parseGoTime(j['expires_at']),
    lastSeen: parseGoTime(j['last_seen']),
    online: _bool(j['online']),
  );
  final String id;
  final String name;
  final String platform;

  /// view | operate | admin
  final String scope;
  final List<String> sessions;

  /// owner | guest
  final String kind;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final DateTime? lastSeen;
  final bool online;
}

/// One finished turn (`turns`, `turn.completed`).
class AgentdTurn {
  const AgentdTurn({required this.turn, this.outcome = '', this.origin = '', this.status = '', this.message, this.startedAt, this.endedAt});
  factory AgentdTurn.fromJson(Json j) => AgentdTurn(
    turn: _int(j['turn']),
    outcome: _str(j['outcome']),
    origin: _str(j['origin']),
    status: _str(j['status']),
    message: _strOrNull(j['message']),
    startedAt: parseGoTime(j['started_at']),
    endedAt: parseGoTime(j['ended_at']),
  );
  final int turn;
  final String outcome; // completed | aborted | exited
  final String origin; // human | act | mail | program
  final String status;
  final String? message;
  final DateTime? startedAt;
  final DateTime? endedAt;
}

/// The OK line of `subscribe`: epoch, last seq and the session snapshot.
class AgentdSubscribeResult {
  const AgentdSubscribeResult({required this.epoch, required this.seq, this.sessions = const []});
  factory AgentdSubscribeResult.fromJson(Json j) => AgentdSubscribeResult(
    epoch: _str(j['epoch']),
    seq: _int(j['seq']),
    sessions: [for (final s in _list(j['sessions'])) AgentdSessionInfo.fromJson(_map(s))],
  );
  final String epoch;
  final int seq;
  final List<AgentdSessionInfo> sessions;
}

// Internal helpers shared with events.dart.
Json jsonMap(Object? v) => _map(v);
String jsonStr(Object? v) => _str(v);
String? jsonStrOrNull(Object? v) => _strOrNull(v);
int jsonInt(Object? v) => _int(v);
bool jsonBool(Object? v) => _bool(v);
Map<String, String> jsonStrMap(Object? v) => _strMap(v);
