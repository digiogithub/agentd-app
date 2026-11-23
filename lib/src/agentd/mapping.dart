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

// A tool call after the bullet: `Bash(ls -la)`, `Read(file)`, `Ran ls`. The
// fallback for lines without chat markup; the call may go on in more lines,
// so the closing parenthesis is optional.
final RegExp _toolCall = RegExp(r'^([A-Z][A-Za-z0-9_.:-]{1,40})\((.*)$');
final RegExp _codexTool = RegExp(r'^(Ran|Explored|Edited|Read|Searched|Updated Plan)\b\s*(.*)$');

// Tool output continuation: claude `⎿`, codex `└`.
final RegExp _resultLine = RegExp(r'^\s*[⎿└]\s*(.*)$');

// Input box borders and separators drawn by TUIs.
final RegExp _decor = RegExp(r'^[\s─━│┃╭╮╰╯┌┐└┘├┤┬┴┼═║╔╗╚╝-]*$');

// The line a harness prints when a turn ends (`✻ Brewed for 8s · done
// 15:16`): a status note, not agent prose.
final RegExp _turnEnd = RegExp(r'^[✻✶✳✢✽·*] \p{Lu}\p{L}* for \d', unicode: true);

/// The tool name when [md] (a line's chat markup after its bullet) starts
/// with a bold run followed by `(` or by nothing: how a harness draws a tool
/// call header (`**Bash**(go test`, `**Read**` while the call is being
/// written, `**agentd - agentd\_inbox (MCP)**(all: true)`). Null otherwise.
String? _boldCall(String md) {
  if (!md.startsWith('**')) return null;
  final end = md.indexOf('**', 2);
  if (end < 0) return null;
  final name = md.substring(2, end).replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!).trim();
  final after = md.substring(end + 2);
  if (name.isEmpty || (after.isNotEmpty && !after.startsWith('('))) return null;
  return name;
}

/// The arguments of a one-line call `(args)`, or of the first line of a
/// longer one `(args`.
String _callArgs(String s) {
  var t = s.trim();
  if (t.startsWith('(')) t = t.substring(1);
  if (t.endsWith(')')) t = t.substring(0, t.length - 1);
  return t.trim();
}

/// Best-effort transcript → chat items, with the rules of the desktop client
/// (agentd `internal/desktopui/app/session/chat.go`). Only `transcript`
/// lines are used (`status` spinners and `dialog` text are left to the
/// session status and [PendingInteraction]); a `gap` becomes a system item.
///
/// - A prompt marker opens a user item; the indented lines under it belong
///   to the same prompt.
/// - A bullet opens a tool item when it is a call header (a bold name in the
///   line's `md`, else the `Name(args` / codex verbs fallback), an agent item
///   otherwise. The indented lines under a tool header continue the call
///   until the output mark (`⎿`, `└`); from there they are its output. Only a
///   line that is not indented ends the tool item.
/// - Agent text is chat markup (the lines' `md`, see [AgentdViewLine.markup]);
///   a run of code lines ([AgentdViewLine.code]) becomes one block between
///   [kChatCodeFence] lines, with its own indentation. User and tool text
///   stay plain.
/// - A turn end note (`✻ Brewed for 8s`) is a system item.
List<ChatItem> chatItemsFromLines(List<AgentdViewLine> lines, {String? harness}) {
  final items = <ChatItem>[];
  ChatRole? role;
  String? title;
  String? meta;
  final buf = <String>[];
  var output = false; // the tool item has reached its output
  var inCode = false; // the agent item ends inside an open code block

  void trimEnd() {
    while (buf.isNotEmpty && buf.last.trim().isEmpty) {
      buf.removeLast();
    }
  }

  void closeCode() {
    if (!inCode) return;
    trimEnd();
    buf.add(kChatCodeFence);
    inCode = false;
  }

  void flush() {
    closeCode();
    if (role != null) {
      trimEnd();
      while (buf.isNotEmpty && buf.first.trim().isEmpty) {
        buf.removeAt(0);
      }
      if (buf.isNotEmpty || title != null) {
        items.add(ChatItem(role: role!, text: buf.join('\n'), title: title, meta: role == ChatRole.tool ? meta : null));
      }
    }
    role = null;
    title = null;
    meta = null;
    output = false;
    buf.clear();
  }

  // Appends one line to the agent item: [md] is its chat markup, [raw] its
  // text as code (indentation kept).
  void addAgent(String md, String raw, bool code) {
    final blank = buf.isNotEmpty && buf.last.trim().isEmpty;
    // An unhighlighted line right under code (a lone brace) is code too.
    if (code || (inCode && !blank)) {
      if (!inCode) {
        if (buf.isNotEmpty && !blank) buf.add('');
        buf.add(kChatCodeFence);
        inCode = true;
      }
      buf.add(raw);
      return;
    }
    if (inCode) {
      closeCode();
      buf.add('');
    }
    buf.add(md);
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

    if (text.isEmpty) {
      // A blank line never ends an item; in a call it is dropped.
      if (role != null && !(role == ChatRole.tool && !output)) buf.add('');
      continue;
    }

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
      final mdBody = _bulletLine.firstMatch(md)?.group(1)!.trim() ?? body;
      if (l.code) {
        role = ChatRole.agent;
        addAgent(mdBody, body, true);
        continue;
      }
      final bold = l.md.isEmpty ? null : _boldCall(mdBody);
      if (bold != null) {
        role = ChatRole.tool;
        title = bold;
        final arg = _callArgs(body.startsWith(bold) ? body.substring(bold.length) : '');
        if (arg.isNotEmpty) buf.add(arg);
        continue;
      }
      final call = _toolCall.firstMatch(body) ?? _codexTool.firstMatch(body);
      if (call != null) {
        role = ChatRole.tool;
        title = call.group(1);
        final arg = identical(call.pattern, _toolCall) ? _callArgs('(${call.group(2)!}') : call.group(2)!.trim();
        if (arg.isNotEmpty) buf.add(arg);
      } else {
        role = ChatRole.agent;
        addAgent(mdBody, body, false);
      }
      continue;
    }
    final indented = text.startsWith(' ') || text.startsWith('\u00a0');
    final r = _resultLine.firstMatch(text);
    if (r != null) {
      if (role != ChatRole.tool) {
        flush();
        role = ChatRole.tool;
      }
      output = true;
      meta ??= _summary(r.group(1)!);
      buf.add(r.group(1)!);
      continue;
    }
    if (!indented) {
      // A line at the left margin is not part of a prompt or a tool call.
      if (_turnEnd.hasMatch(text)) {
        flush();
        items.add(ChatItem(role: ChatRole.system, text: text));
        continue;
      }
      if (role != ChatRole.agent) {
        flush();
        role = ChatRole.agent;
      }
      addAgent(md, text, l.code);
      continue;
    }
    switch (role) {
      case ChatRole.tool:
        // Before the output mark the call goes on (a wrapped path, a
        // multi-line command); after it, more output.
        buf.add(output ? _dedent(text, 5) : _dedent(text, 2));
      case ChatRole.user:
        buf.add(text.trim());
      case ChatRole.agent || ChatRole.system || null:
        role = ChatRole.agent;
        addAgent(_dedent(md, 2), _dedent(text, 2), l.code);
    }
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

/// [s] without up to [max] leading spaces: continuation lines are indented
/// under the bullet (2 columns), tool output under its mark (5).
String _dedent(String s, int max) {
  var i = 0;
  while (i < max && i < s.length && (s[i] == ' ' || s[i] == '\u00a0')) {
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

/// Task status word → [TaskStatus] (unknown words are pending).
TaskStatus mapTaskStatus(String status) => switch (status) {
  'in_progress' => TaskStatus.inProgress,
  'blocked' => TaskStatus.blocked,
  'done' => TaskStatus.done,
  'cancelled' => TaskStatus.cancelled,
  _ => TaskStatus.pending,
};

AgentTask toAgentTask(AgentdTask t) =>
    AgentTask(id: t.id, title: t.title, status: mapTaskStatus(t.status), note: t.note, updatedAt: t.updatedAt);

/// Answer of op board → HostBoard.
HostBoard toHostBoard(AgentdBoard b, {required String hostId}) => HostBoard(
  hostId: hostId,
  unreadHuman: b.unreadHuman,
  sessions: [
    for (final s in b.sessions)
      BoardSession(
        hostId: hostId,
        name: s.name,
        status: mapStatus(s.status),
        attention: s.attention,
        turn: s.turn > 0 ? s.turn : null,
        preview: s.preview,
        tasks: [for (final t in s.tasks) toAgentTask(t)],
        questions: [
          for (final q in s.questions) AgentQuestion(id: q.id, body: q.body, options: q.options, taskId: q.task, createdAt: q.createdAt),
        ],
      ),
  ],
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
