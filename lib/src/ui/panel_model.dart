// What the Panel shows, computed from the hosts' boards (tasks, questions)
// and the live sessions (terminal menus).

import '../core/contracts.dart';

/// Where a message written in the Panel goes.
enum SendTarget {
  /// The agent's mailbox: delivered when it is free.
  mailbox,

  /// Typed now in its terminal.
  prompt,
}

/// Something that waits for the human.
sealed class WaitingItem {
  const WaitingItem();
  String get hostId;
  String get name;
  DateTime? get since;
}

/// A question an agent asked through the mailbox.
class QuestionWaiting extends WaitingItem {
  const QuestionWaiting(this.session, this.question);
  final BoardSession session;
  final AgentQuestion question;

  @override
  String get hostId => session.hostId;
  @override
  String get name => session.name;
  @override
  DateTime? get since => question.createdAt;
}

/// A menu on the agent's terminal (permission, question, plan).
class MenuWaiting extends WaitingItem {
  const MenuWaiting(this.session);
  final AgentSession session;

  PendingInteraction get pending => session.pending!;

  @override
  String get hostId => session.hostId;
  @override
  String get name => session.name;
  @override
  DateTime? get since => session.updatedAt;
}

/// A task its agent marked as blocked.
class BlockedWaiting extends WaitingItem {
  const BlockedWaiting(this.session, this.task);
  final BoardSession session;
  final AgentTask task;

  @override
  String get hostId => session.hostId;
  @override
  String get name => session.name;
  @override
  DateTime? get since => task.updatedAt;
}

class PanelData {
  const PanelData({this.waiting = const [], this.agents = const [], this.inProgress = 0, this.pending = 0});

  /// Questions, then terminal menus, then blocked tasks.
  final List<WaitingItem> waiting;
  final List<BoardSession> agents;

  /// Tasks in progress / pending over every agent.
  final int inProgress;
  final int pending;
}

/// The first paragraph of a question (its headline) and the rest.
(String, String) splitQuestion(String body) {
  final t = body.trim();
  final i = t.indexOf(RegExp(r'\n\s*\n'));
  if (i < 0) return (t, '');
  return (t.substring(0, i).trim(), t.substring(i).trim());
}

/// "3 / 7": done over the tasks that count.
String progressLabel(BoardSession s) => '${s.done} / ${s.total}';

double progressOf(BoardSession s) => s.total <= 0 ? 0 : s.done / s.total;

int _rank(BoardSession s) {
  if (s.questions.isNotEmpty || s.count(TaskStatus.blocked) > 0 || s.status == AgentStatus.waiting) return 0;
  if (s.status == AgentStatus.working || s.status == AgentStatus.starting) return 1;
  if (s.tasks.isNotEmpty) return 2;
  return s.status == AgentStatus.exited ? 4 : 3;
}

/// Builds the Panel from [boards] and the live [sessions]; [hostId] narrows
/// it to one host. Hosts without a board (no agentd, a daemon older than
/// the dashboard) list their agentd sessions with status and preview only.
PanelData buildPanel({required Iterable<HostBoard> boards, required List<AgentSession> sessions, String? hostId}) {
  bool shown(String h) => hostId == null || h == hostId;
  final withBoard = <String>{};
  final agents = <BoardSession>[];
  for (final b in boards) {
    if (!b.available || !shown(b.hostId)) continue;
    withBoard.add(b.hostId);
    agents.addAll(b.sessions);
  }
  for (final s in sessions) {
    if (s.source != SessionSource.agentd || !shown(s.hostId) || withBoard.contains(s.hostId)) continue;
    agents.add(BoardSession(hostId: s.hostId, name: s.name, status: s.status, attention: s.attention, turn: s.turn, preview: s.preview));
  }
  final ranked = [for (final (i, a) in agents.indexed) (_rank(a), i, a)]..sort((x, y) => x.$1 != y.$1 ? x.$1 - y.$1 : x.$2 - y.$2);

  int byTime(WaitingItem a, WaitingItem b) => (a.since ?? DateTime(0)).compareTo(b.since ?? DateTime(0));
  final questions = <WaitingItem>[
    for (final a in agents)
      for (final q in a.questions) QuestionWaiting(a, q),
  ]..sort(byTime);
  final menus = <WaitingItem>[
    for (final s in sessions)
      if (s.source == SessionSource.agentd && s.pending != null && shown(s.hostId)) MenuWaiting(s),
  ]..sort(byTime);
  final blocked = <WaitingItem>[
    for (final a in agents)
      for (final t in a.tasks)
        if (t.status == TaskStatus.blocked) BlockedWaiting(a, t),
  ]..sort(byTime);

  return PanelData(
    waiting: [...questions, ...menus, ...blocked],
    agents: [for (final r in ranked) r.$3],
    inProgress: agents.fold(0, (n, a) => n + a.count(TaskStatus.inProgress)),
    pending: agents.fold(0, (n, a) => n + a.count(TaskStatus.pending)),
  );
}
