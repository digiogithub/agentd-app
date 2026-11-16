// Small presentation helpers shared by the screens.

import '../core/contracts.dart';

/// "hace 3 min", "hace 2 h", "hace 2 días".
String relativeTime(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 45) return 'ahora';
  if (d.inMinutes < 60) return 'hace ${d.inMinutes < 1 ? 1 : d.inMinutes} min';
  if (d.inHours < 24) return 'hace ${d.inHours} h';
  final days = d.inDays;
  return days == 1 ? 'hace 1 día' : 'hace $days días';
}

/// "2 min", "40 s": how long a session has been in its state.
String shortDuration(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return '${d.inSeconds < 0 ? 0 : d.inSeconds} s';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  return '${d.inHours} h';
}

/// Title of a session: agentd names as they are, mux sessions with their source.
String sessionTitle(AgentSession s) => switch (s.source) {
  SessionSource.agentd => s.name,
  SessionSource.shell => 'ssh · ${s.name}',
  _ => '${s.source.name} · ${s.name}',
};

String sourceLabel(SessionSource s) => s == SessionSource.agentd ? 'agentd' : 'SSH';

/// Letter shown in the avatar (codex is "X" in the design).
String avatarLetter(AgentSession s) {
  final h = (s.harness ?? s.name).toLowerCase();
  if (h.startsWith('codex')) return 'X';
  return h.isEmpty ? '?' : h[0].toUpperCase();
}

final _allowRe = RegExp(r'^\s*(\d+[.)]\s*)?(yes|s[ií]|allow|permitir|approve|aprobar)\b', caseSensitive: false);
final _denyRe = RegExp(r'^\s*(\d+[.)]\s*)?(no|deny|denegar|reject|rechazar)\b', caseSensitive: false);

/// A permission (classified by the data layer) that can be answered with
/// Permitir / Denegar: it has an allowing and a denying option.
bool isPermission(PendingInteraction p) => p.kind == PendingKind.permission && allowOption(p) != null && denyOption(p) != null;

/// The option that allows: the first labelled so, else the first option of
/// a permission menu (agents list "Yes" first).
SessionOption? allowOption(PendingInteraction p) {
  for (final o in p.options) {
    if (_allowRe.hasMatch(o.label)) return o;
  }
  return p.kind == PendingKind.permission && p.options.length >= 2 ? p.options.first : null;
}

/// The option that denies: the last labelled so, else the last option of a
/// permission menu.
SessionOption? denyOption(PendingInteraction p) {
  for (final o in p.options.reversed) {
    if (_denyRe.hasMatch(o.label)) return o;
  }
  return p.kind == PendingKind.permission && p.options.length >= 2 ? p.options.last : null;
}

/// Section label of a pending interaction.
String pendingLabel(PendingInteraction p) => switch (p.kind) {
  PendingKind.permission => 'Permiso',
  PendingKind.plan => 'Plan',
  _ => 'Pregunta',
};

/// What a permission is about: the command / file, else the question.
String pendingSubject(PendingInteraction p) => p.detail ?? p.question;

/// Inbox groups of the Agents screen.
enum SessionGroup { needsAnswer, working, done }

SessionGroup groupOf(AgentSession s) {
  if (s.pending != null || s.status == AgentStatus.waiting) return SessionGroup.needsAnswer;
  if (s.status == AgentStatus.working || s.status == AgentStatus.starting) return SessionGroup.working;
  return SessionGroup.done;
}

String plural(int n, String one, String many) => n == 1 ? '$n $one' : '$n $many';

// ---------------------------------------------------------------------------
// Projects (Agents grouped by directory)
// ---------------------------------------------------------------------------

/// Label of the group of sessions with no project.
const noProjectLabel = 'Sin proyecto';

/// A project group of the Agents screen: one host + one directory.
class ProjectGroup {
  ProjectGroup({required this.hostId, required this.path, required this.label, required this.sessions});

  final String hostId;

  /// Directory (or project name) the group is keyed by; '' = no project.
  final String path;
  final String label;
  final List<AgentSession> sessions;

  String get key => '$hostId|$path';
  bool get hasProject => path.isNotEmpty;
  int get needsAnswer => sessions.where((s) => groupOf(s) == SessionGroup.needsAnswer).length;
  DateTime? get latest => sessions.map((s) => s.updatedAt).whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
}

/// Directory a session belongs to: its cwd (trailing slashes removed), else
/// its project name, else '' (no project).
String projectPathOf(AgentSession s) {
  var p = (s.cwd ?? '').trim();
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  if (p.isNotEmpty) return p;
  return (s.project ?? '').trim();
}

/// `/home/u/src/api` -> `~/src/api` (the home directory guessed from the
/// path itself: `/home/<u>`, `/Users/<u>`, `/root`).
String shortPath(String path) {
  final m = RegExp(r'^(/home/[^/]+|/Users/[^/]+|/root)(?=/|$)').firstMatch(path);
  return m == null ? path : '~${path.substring(m.end)}';
}

/// Sessions grouped by host + project. Inside a group: needs-answer first,
/// then working, then the rest by last update; groups by attention, then
/// most recent activity, then label.
List<ProjectGroup> groupByProject(Iterable<AgentSession> sessions) {
  final byKey = <String, ProjectGroup>{};
  for (final s in sessions) {
    final path = projectPathOf(s);
    final g = byKey.putIfAbsent(
      '${s.hostId}|$path',
      () => ProjectGroup(hostId: s.hostId, path: path, label: path.isEmpty ? noProjectLabel : shortPath(path), sessions: []),
    );
    g.sessions.add(s);
  }
  int rank(AgentSession s) => switch (groupOf(s)) {
    SessionGroup.needsAnswer => 0,
    SessionGroup.working => 1,
    SessionGroup.done => 2,
  };
  int byTime(DateTime? a, DateTime? b) => (b ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(a ?? DateTime.fromMillisecondsSinceEpoch(0));
  for (final g in byKey.values) {
    g.sessions.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : byTime(a.updatedAt, b.updatedAt);
    });
  }
  final list = byKey.values.toList()
    ..sort((a, b) {
      final att = (b.needsAnswer > 0 ? 1 : 0).compareTo(a.needsAnswer > 0 ? 1 : 0);
      if (att != 0) return att;
      final t = byTime(a.latest, b.latest);
      if (t != 0) return t;
      return a.label.compareTo(b.label);
    });
  return list;
}
