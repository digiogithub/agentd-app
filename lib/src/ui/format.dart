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
