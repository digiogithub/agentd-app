// Mapping from agentd wire models to the app contracts (core/contracts.dart).

import '../core/contracts.dart';
import 'models.dart';

/// Maps a daemon status word (view / ls `status`, or the process `state`
/// when there is no status yet) to [AgentStatus].
AgentStatus mapStatus(String? status, {String? state}) {
  switch (status) {
    case 'working':
      return AgentStatus.working;
    case 'waiting':
      return AgentStatus.waiting;
    case 'idle':
      return AgentStatus.idle;
    case 'starting':
      return AgentStatus.starting;
    case 'exited':
      return AgentStatus.exited;
  }
  switch (state) {
    case 'starting':
      return AgentStatus.starting;
    case 'exited':
      return AgentStatus.exited;
  }
  return AgentStatus.unknown;
}

/// Harness and project of a session: labels `agentd.harness` /
/// `herdr.space` when set, else the `<harness>@<project>` naming
/// convention, else the profile and the cwd's base name.
({String? harness, String? project}) harnessAndProject(AgentdSessionInfo s) {
  String? harness = s.labels['agentd.harness'];
  String? project = s.labels['herdr.space'];
  final at = s.name.indexOf('@');
  if (at > 0) {
    harness ??= s.name.substring(0, at);
    if (at + 1 < s.name.length) project ??= s.name.substring(at + 1);
  }
  if (harness == null || harness.isEmpty) {
    harness = s.profile.isNotEmpty && s.profile != 'default' ? s.profile : (s.cmd.isNotEmpty ? _base(s.cmd.first) : null);
  }
  if ((project == null || project.isEmpty) && s.cwd.isNotEmpty) project = _base(s.cwd);
  return (harness: harness, project: project);
}

String _base(String path) {
  var p = path;
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  final i = p.lastIndexOf('/');
  return i >= 0 ? p.substring(i + 1) : p;
}

/// SessionInfo (ls, run, subscribe snapshot, session.* events) → AgentSession.
AgentSession toAgentSession(AgentdSessionInfo s, {required String hostId, PendingInteraction? pending}) {
  final hp = harnessAndProject(s);
  return AgentSession(
    hostId: hostId,
    source: SessionSource.agentd,
    name: s.name,
    harness: hp.harness,
    project: hp.project,
    status: mapStatus(s.status, state: s.state),
    attention: s.attention,
    preview: s.preview,
    cwd: s.cwd.isEmpty ? null : s.cwd,
    turn: s.turn,
    updatedAt: s.lastOutput ?? s.startedAt,
    pending: pending,
    detail: s.title,
  );
}

/// The pending question of a view: set when the agent is `waiting`, a dialog
/// is on screen or a menu was detected. [reportedKind] is the OSC 7501
/// `kind` the program reported (`permission`, `question`, `auth`), when the
/// session listing carries one: it wins over the screen heuristics.
PendingInteraction? pendingOf(AgentdView v, {String? reportedKind}) {
  if (v.status != 'waiting' && v.dialogQuestion == null && v.options.isEmpty) return null;
  final c = classifyPending(
    question: v.dialogQuestion ?? '',
    dialogLines: [for (final l in v.lines) if (l.role == 'dialog') l.text],
    options: v.options,
    reportedKind: reportedKind,
  );
  return PendingInteraction(
    question: c.question,
    options: [
      for (final o in v.options)
        SessionOption(
          id: o.id,
          label: o.label,
          index: o.index > 0 ? o.index : null,
          selected: o.selected,
          kind: mapOptionKind(o.kind),
          checked: o.checked,
        ),
    ],
    revision: v.revision,
    epoch: v.epoch,
    kind: c.kind,
    detail: c.detail,
  );
}

/// agentd option kind (`numbered | pointer | checkbox | yesno`) → [OptionKind].
OptionKind? mapOptionKind(String kind) => switch (kind) {
  'numbered' => OptionKind.numbered,
  'pointer' => OptionKind.pointer,
  'checkbox' => OptionKind.checkbox,
  'yesno' => OptionKind.yesno,
  _ => null,
};

// Frame glyphs drawn around dialogs (left / right borders).
final RegExp _frameEdge = RegExp(r'^[\s│┃║╎┆|]+|[\s│┃║╎┆|]+$');

// Tool headers of permission dialogs: Claude Code "Bash command", "Edit
// file", "Fetch", "Tool use"...
final RegExp _toolHeader = RegExp(
  r'^(bash|shell|powershell)( command)?$|^(edit|create|write|update|read|delete|overwrite) (file|files)$|^(web ?)?fetch$|^tool use$|^mcp( tool)?$',
  caseSensitive: false,
);

// Phrasing of a permission request (Claude Code, Codex, Gemini, generic).
final RegExp _permissionText = RegExp(
  r'do you want to (proceed|make (this|these) edits?|create|allow|run|delete|overwrite|write|apply|execute)|'
  r'would you like to (run|make|apply|allow|execute)|allow .{0,80}\?|\bpermission\b|\bapprove\b',
  caseSensitive: false,
);

// Option labels that only exist in permission menus.
final RegExp _permissionLabel = RegExp(r"don'?t ask again|\balways allow\b|\ballow (all|once|always)\b|\bfor this session\b", caseSensitive: false);

// Plan approval (Claude Code plan mode: "No, keep planning"; "Ready to code?").
final RegExp _planLabel = RegExp(r'keep planning|auto-accept edits|manually approve edits', caseSensitive: false);
final RegExp _planText = RegExp(r'ready to code\?|\bplan\b.{0,40}\b(proceed|approve|accept)|exit plan mode', caseSensitive: false);

/// Kind, cleaned-up question and detail (tool command / file) of a dialog.
/// [question] is the daemon's `dialog.question` (the rows above the options,
/// or the first row of a framed dialog), [dialogLines] the view lines with
/// role `dialog`.
({PendingKind kind, String question, String? detail}) classifyPending({
  required String question,
  List<String> dialogLines = const [],
  List<AgentdViewOption> options = const [],
  String? reportedKind,
}) {
  final ctx = <String>[];
  for (final raw in [...dialogLines, ...question.split('\n')]) {
    final t = raw.replaceAll(_frameEdge, '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty || _decor.hasMatch(t)) continue;
    if (options.any((o) => t.contains(o.label) && t.length <= o.label.length + 6)) continue; // option rows
    if (!ctx.contains(t)) ctx.add(t);
  }
  final text = ctx.join('\n');
  final labels = options.map((o) => o.label).join('\n');

  // Detail: the line under a tool header, else a Codex `$ command` line.
  String? detail;
  for (var i = 0; i < ctx.length && detail == null; i++) {
    if (_toolHeader.hasMatch(ctx[i])) {
      for (final l in ctx.skip(i + 1)) {
        if (l.endsWith('?') || _toolHeader.hasMatch(l)) break;
        detail = l.startsWith(r'$ ') ? l.substring(2).trim() : l;
        break;
      }
    }
  }
  detail ??= ctx.where((l) => l.startsWith(r'$ ') && l.length > 2).map((l) => l.substring(2).trim()).firstOrNull;

  // Question: the last line asking something, when the daemon's question is
  // a tool header or a multi-line block.
  var q = question.trim();
  final asking = ctx.where((l) => l.endsWith('?')).lastOrNull;
  final firstLine = q.split('\n').first.trim();
  if (asking != null && (q.contains('\n') || _toolHeader.hasMatch(firstLine) || q.isEmpty)) q = asking;

  PendingKind kind;
  switch (reportedKind) {
    case 'permission':
    case 'auth':
      kind = PendingKind.permission;
    case 'question':
      kind = PendingKind.question;
    default:
      if (_planLabel.hasMatch(labels) || _planText.hasMatch(text)) {
        kind = PendingKind.plan;
      } else if (detail != null ||
          ctx.any(_toolHeader.hasMatch) ||
          _permissionText.hasMatch(text) ||
          _permissionLabel.hasMatch(labels)) {
        kind = PendingKind.permission;
      } else if (options.isNotEmpty || q.isNotEmpty) {
        kind = PendingKind.question;
      } else {
        kind = PendingKind.unknown;
      }
  }
  return (kind: kind, question: q, detail: detail);
}

/// Applies a view to [base] (the session as listed) and maps it to a
/// [SessionView]. A not-modified view must not be passed here.
SessionView toSessionView(AgentdView v, AgentSession base, {String? reportedKind}) {
  final pending = pendingOf(v, reportedKind: reportedKind);
  final session = AgentSession(
    hostId: base.hostId,
    source: base.source,
    name: base.name,
    harness: base.harness,
    project: base.project,
    status: v.status.isEmpty ? base.status : mapStatus(v.status),
    attention: v.attention.set,
    preview: base.preview,
    cwd: v.cwd ?? base.cwd,
    turn: base.turn,
    updatedAt: base.updatedAt,
    pending: pending,
    detail: v.title ?? base.detail,
  );
  return SessionView(
    session: session,
    items: chatItemsFromLines(v.lines, harness: base.harness),
    inputText: v.input.text,
    ghost: v.input.ghost.isEmpty ? null : v.input.ghost,
    revision: v.revision,
    epoch: v.epoch,
  );
}

// Prompt markers that start a user turn: claude `❯`, codex `›`, generic `>`.
final RegExp _userLine = RegExp(r'^\s{0,2}[❯›>][  ](.*)$');

// Agent / tool bullets: claude `⏺`, codex `•`, generic `●`.
final RegExp _bulletLine = RegExp(r'^\s{0,2}[⏺•●][  ](.*)$');

// A tool call after the bullet: `Bash(ls -la)`, `Read(file)`, `Ran ls`.
final RegExp _toolCall = RegExp(r'^([A-Z][A-Za-z0-9_.:-]{1,40})\((.*)\)\s*$');
final RegExp _codexTool = RegExp(r'^(Ran|Explored|Edited|Read|Searched|Updated Plan)\b\s*(.*)$');

// Tool output continuation: claude `⎿`, codex `└`.
final RegExp _resultLine = RegExp(r'^\s*[⎿└]\s?(.*)$');

// Input box borders and separators drawn by TUIs.
final RegExp _decor = RegExp(r'^[\s─━│┃╭╮╰╯┌┐└┘├┤┬┴┼═║╔╗╚╝-]*$');

/// Best-effort transcript → chat items. Only `transcript` lines are used
/// (`status` spinners and `dialog` text are left to the session status and
/// [PendingInteraction]); a `gap` becomes a system item. Lines starting with
/// a prompt marker open a user item, bullets open an agent (or tool, when
/// the bullet is a `Name(args)` call) item, `⎿` lines and plain lines extend
/// the current item. Agent text is chat markup (the lines' `md`, see
/// [AgentdViewLine.markup]); user and tool text stay plain.
List<ChatItem> chatItemsFromLines(List<AgentdViewLine> lines, {String? harness}) {
  final items = <ChatItem>[];
  ChatRole? role;
  String? title;
  String? meta;
  final buf = <String>[];

  void flush() {
    if (role == null) return;
    while (buf.isNotEmpty && buf.last.trim().isEmpty) {
      buf.removeLast();
    }
    while (buf.isNotEmpty && buf.first.trim().isEmpty) {
      buf.removeAt(0);
    }
    if (buf.isNotEmpty || title != null) {
      items.add(ChatItem(role: role!, text: buf.join('\n'), title: title, meta: role == ChatRole.tool ? meta : null));
    }
    role = null;
    title = null;
    meta = null;
    buf.clear();
  }

  for (final l in lines) {
    if (l.role == 'gap') {
      flush();
      items.add(const ChatItem(role: ChatRole.system, text: '…'));
      continue;
    }
    if (l.role != 'transcript') continue;
    final text = l.text.trimRight();
    // Agent prose keeps the line's chat markup (headings, bold, code).
    final md = l.markup.trimRight();
    if (text.isNotEmpty && _decor.hasMatch(text)) continue;

    final u = _userLine.firstMatch(text);
    if (u != null) {
      flush();
      role = ChatRole.user;
      buf.add(u.group(1)!.trim());
      continue;
    }
    final b = _bulletLine.firstMatch(text);
    if (b != null) {
      flush();
      final body = b.group(1)!.trim();
      final call = _toolCall.firstMatch(body) ?? _codexTool.firstMatch(body);
      if (call != null) {
        role = ChatRole.tool;
        title = call.group(1);
        final arg = call.group(2)!.trim();
        if (arg.isNotEmpty) buf.add(arg);
      } else {
        role = ChatRole.agent;
        buf.add(_bulletLine.firstMatch(md)?.group(1)!.trim() ?? body);
      }
      continue;
    }
    final r = _resultLine.firstMatch(text);
    if (r != null) {
      if (role != ChatRole.tool) {
        flush();
        role = ChatRole.tool;
      }
      meta ??= _summary(r.group(1)!);
      buf.add(r.group(1)!);
      continue;
    }
    if (role == null) {
      if (text.trim().isEmpty) continue;
      role = ChatRole.agent;
    }
    buf.add(_dedent(role == ChatRole.agent ? md : text));
  }
  flush();
  return items;
}

/// First output line of a tool, as a short summary (null when blank).
String? _summary(String line) {
  final t = line.trim();
  if (t.isEmpty) return null;
  return t.length <= 60 ? t : '${t.substring(0, 59)}…';
}

String _dedent(String s) {
  // Continuation lines are indented under the bullet (2 columns).
  var i = 0;
  while (i < 2 && i < s.length && (s[i] == ' ' || s[i] == ' ')) {
    i++;
  }
  return s.substring(i);
}

MailState mapMailState(String s) => switch (s) {
  'queued' => MailState.queued,
  'delivered' => MailState.delivered,
  'read' => MailState.read,
  'replied' => MailState.replied,
  'unclaimed' => MailState.unclaimed,
  _ => MailState.queued,
};

/// Mailbox message (inbox, read, reply, send, queue items) → MailMessage.
MailMessage toMailMessage(AgentdMessage m) => MailMessage(
  id: m.id,
  from: m.sender,
  to: m.recipient,
  subject: m.subject,
  body: m.body,
  state: mapMailState(m.state),
  createdAt: m.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  replyTo: m.replyTo,
  queue: m.queue,
);

/// Queue listing (op queue without name) → WorkQueue.
WorkQueue toWorkQueue(AgentdQueueCount q) => WorkQueue(q.name, q.unclaimed);

/// Applies a status.changed / attention.changed / session.labels style
/// update to a listed session (the event bus carries no preview).
AgentSession withStatus(AgentSession s, {AgentStatus? status, bool? attention, int? turn}) => AgentSession(
  hostId: s.hostId,
  source: s.source,
  name: s.name,
  harness: s.harness,
  project: s.project,
  status: status ?? s.status,
  attention: attention ?? s.attention,
  preview: s.preview,
  cwd: s.cwd,
  turn: turn ?? s.turn,
  updatedAt: DateTime.now(),
  pending: status == null || status == AgentStatus.waiting ? s.pending : null,
  detail: s.detail,
);
