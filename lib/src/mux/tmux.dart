// tmux adapter. Commands and format variables from tmux(1)
// (https://man7.org/linux/man-pages/man1/tmux.1.html, FORMATS and the
// list-sessions / list-panes / attach-session / new-session / kill-session
// entries); tmux >= 2.6 for `-c` on new-session and `=` exact targets:
//
//   list:    tmux list-sessions -F '<session vars joined by TAB>'
//   panes:   tmux list-panes -a -F '<pane vars joined by TAB>'
//   attach:  tmux attach-session -t =S              (PTY)
//   launch:  tmux new-session -d -s S -c DIR 'CMD'  (or new-window -t =S:)
//   kill:    tmux kill-session -t =S
//
// "no server running" / "error connecting to ..." mean no sessions.

import 'dart:convert';

import '../core/contracts.dart';
import 'harness.dart';
import 'mux_adapter.dart';
import 'quote.dart';

class TmuxSessionLine {
  const TmuxSessionLine({required this.name, this.windows = 0, this.attached = 0, this.activity, this.created, this.path});
  final String name;
  final int windows;
  final int attached; // number of attached clients
  final DateTime? activity;
  final DateTime? created;
  final String? path;
}

class TmuxPane {
  const TmuxPane({required this.session, this.window = 0, this.pane = 0, this.active = false, this.windowActive = false, this.command, this.path, this.title, this.dead = false});
  final String session;
  final int window;
  final int pane;
  final bool active;
  final bool windowActive;
  final String? command;
  final String? path;
  final String? title;
  final bool dead;
}

const _sessionVars = ['session_name', 'session_windows', 'session_attached', 'session_activity', 'session_created', 'session_path'];
const _paneVars = ['session_name', 'window_index', 'pane_index', 'pane_active', 'window_active', 'pane_current_command', 'pane_current_path', 'pane_title', 'pane_dead'];

String _format(List<String> vars) => vars.map((v) => '#{$v}').join('\t');

/// True when [r] is tmux saying there is no server (hence no sessions).
bool tmuxNoServer(ExecResult r) {
  final e = r.stderr.toLowerCase();
  return e.contains('no server running') || e.contains('error connecting to') || e.contains('no sessions') || e.contains('failed to connect to server');
}

DateTime? _epoch(String s) {
  final n = int.tryParse(s.trim());
  return n == null || n <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(n * 1000, isUtc: true);
}

String? _nonEmpty(String? s) => s == null || s.isEmpty ? null : s;

/// Some tmux builds print non-printable characters of a format as octal
/// escapes; accept `\011` and a literal `\t` as the separator too.
List<String> _fields(String line) => line.replaceAll(r'\011', '\t').replaceAll(r'\t', '\t').split('\t');

/// Parses the output of [TmuxAdapter.listCommand].
List<TmuxSessionLine> parseTmuxSessions(String out) {
  final res = <TmuxSessionLine>[];
  for (final line in const LineSplitter().convert(out)) {
    if (line.trim().isEmpty) continue;
    final f = _fields(line);
    String at(int i) => i < f.length ? f[i] : '';
    res.add(TmuxSessionLine(
      name: at(0),
      windows: int.tryParse(at(1)) ?? 0,
      attached: int.tryParse(at(2)) ?? 0,
      activity: _epoch(at(3)),
      created: _epoch(at(4)),
      path: _nonEmpty(at(5)),
    ));
  }
  return res;
}

/// Parses the output of [TmuxAdapter.panesCommand].
List<TmuxPane> parseTmuxPanes(String out) {
  final res = <TmuxPane>[];
  for (final line in const LineSplitter().convert(out)) {
    if (line.trim().isEmpty) continue;
    final f = _fields(line);
    String at(int i) => i < f.length ? f[i] : '';
    res.add(TmuxPane(
      session: at(0),
      window: int.tryParse(at(1)) ?? 0,
      pane: int.tryParse(at(2)) ?? 0,
      active: at(3) == '1',
      windowActive: at(4) == '1',
      command: _nonEmpty(at(5)),
      path: _nonEmpty(at(6)),
      title: _nonEmpty(at(7)),
      dead: at(8) == '1',
    ));
  }
  return res;
}

class TmuxAdapter implements MuxAdapter {
  TmuxAdapter(this.shell, {required this.hostId, DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final RemoteShell shell;
  final String hostId;
  final DateTime Function() _now;

  @override
  SessionSource get source => SessionSource.tmux;

  static final listCommand = 'tmux list-sessions -F ${posixQuote(_format(_sessionVars))}';
  static final panesCommand = 'tmux list-panes -a -F ${posixQuote(_format(_paneVars))}';

  @override
  Future<List<AgentSession>> list({bool withPanes = true}) async {
    final r = await shell.exec(listCommand);
    checkInstalled('tmux', r);
    if (!r.ok) {
      if (tmuxNoServer(r)) return const [];
      throw MuxException('tmux list-sessions failed: ${r.stderr.trim()}', result: r);
    }
    final sessions = parseTmuxSessions(r.stdout);
    var panes = const <TmuxPane>[];
    if (withPanes && sessions.isNotEmpty) {
      final p = await shell.exec(panesCommand);
      if (p.ok) panes = parseTmuxPanes(p.stdout);
    }
    return [for (final s in sessions) toSession(s, withPanes ? panes.where((p) => p.session == s.name).toList() : null)];
  }

  AgentSession toSession(TmuxSessionLine s, List<TmuxPane>? panes) {
    final split = splitSessionName(s.name);
    final live = panes?.where((p) => !p.dead).toList() ?? const <TmuxPane>[];
    // The active pane of the active window first.
    final ordered = [...live]..sort((a, b) => _rank(b) - _rank(a));
    String? harness;
    for (final p in ordered) {
      harness = guessHarness(p.command, title: p.title);
      if (harness != null) break;
    }
    harness ??= split.harness;
    final cwd = ordered.isNotEmpty ? ordered.first.path : s.path;
    final detail = <String>[
      '${s.windows} ${s.windows == 1 ? 'window' : 'windows'}',
      if (panes != null) '${live.length} ${live.length == 1 ? 'pane' : 'panes'}',
      if (s.attached > 0) 'attached',
    ];
    final allDead = panes != null && panes.isNotEmpty && live.isEmpty;
    return AgentSession(
      hostId: hostId,
      source: SessionSource.tmux,
      name: s.name,
      harness: harness,
      project: split.project ?? baseName(cwd),
      cwd: cwd,
      status: allDead ? AgentStatus.exited : AgentStatus.unknown,
      updatedAt: s.activity ?? s.created,
      detail: detail.join(' · '),
    );
  }

  static int _rank(TmuxPane p) => (p.windowActive ? 2 : 0) + (p.active ? 1 : 0);

  static String _target(String name) => posixQuote('=$name');

  static String attachCommand(String name) => 'tmux attach-session -t ${_target(name)}';

  @override
  Future<PtySession> attach(String name, {int cols = 80, int rows = 24}) =>
      shell.pty(command: attachCommand(name), cols: cols, rows: rows);

  /// The command [launch] runs: a new detached session, or a new window
  /// when the session already exists. tmux runs the command string with
  /// the user's default shell.
  static String launchCommand({required String session, required String cwd, required List<String> command, String? windowName}) {
    // An empty command opens the default shell (terminal only).
    final s = posixQuote(session);
    final dir = posixDir(cwd);
    final cmd = command.isEmpty ? '' : ' ${posixQuote(posixJoin(command))}';
    final n = windowName == null ? '' : ' -n ${posixQuote(windowName)}';
    return 'if tmux has-session -t ${_target(session)} 2>/dev/null; '
        'then tmux new-window -t ${posixQuote('=$session:')}$n -c $dir$cmd; '
        'else tmux new-session -d -s $s$n -c $dir$cmd; fi';
  }

  @override
  Future<AgentSession> launch({required String session, required String cwd, required List<String> command, String? harness}) async {
    harness ??= guessHarness(command.join(' '));
    final r = await shell.exec(launchCommand(session: session, cwd: cwd, command: command, windowName: harness));
    checkInstalled('tmux', r);
    if (!r.ok) throw MuxException('tmux new-session failed: ${r.stderr.trim()}', result: r);
    return AgentSession(
      hostId: hostId,
      source: SessionSource.tmux,
      name: session,
      harness: harness,
      project: splitSessionName(session).project ?? baseName(cwd),
      cwd: cwd,
      updatedAt: _now(),
    );
  }

  @override
  Future<void> kill(String name) async {
    final r = await shell.exec('tmux kill-session -t ${_target(name)}');
    checkInstalled('tmux', r);
    if (!r.ok && !tmuxNoServer(r) && !r.stderr.contains("can't find session")) {
      throw MuxException('tmux kill-session failed: ${r.stderr.trim()}', result: r);
    }
  }
}
