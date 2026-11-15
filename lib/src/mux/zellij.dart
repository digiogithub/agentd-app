// zellij adapter (CLI 0.44.x; checked against `zellij --help`,
// `zellij list-sessions --help`, `zellij attach --help`,
// `zellij action new-pane --help` and `zellij action list-panes --help` of
// zellij 0.44.3, and https://zellij.dev/documentation/cli-actions).
//
//   list:    zellij list-sessions --no-formatting
//   panes:   zellij --session S action list-panes --json --command --state
//            (0.44+; older versions lack it and simply report no panes)
//   attach:  zellij attach S                     (PTY; resurrects EXITED ones)
//   launch:  zellij attach --create-background S
//            zellij --session S action new-pane --cwd DIR --name H -- CMD...
//   kill:    zellij delete-session --force S

import 'dart:convert';

import '../core/contracts.dart';
import 'harness.dart';
import 'mux_adapter.dart';
import 'quote.dart';

/// One line of `zellij list-sessions --no-formatting`.
class ZellijSessionLine {
  const ZellijSessionLine({required this.name, this.createdAgo, this.current = false, this.exited = false});
  final String name;
  final Duration? createdAgo;
  final bool current;
  final bool exited;
}

/// One terminal pane of `zellij action list-panes --json`.
class ZellijPane {
  const ZellijPane({required this.id, this.title, this.command, this.exited = false, this.focused = false, this.tabName});
  final int id;
  final String? title;
  final String? command;
  final bool exited;
  final bool focused;
  final String? tabName;
}

final _lineRe = RegExp(r'^(\S+)\s*\[Created\s+(.*?)\s+ago\]\s*(.*)$');
final _durRe = RegExp(r'(\d+)\s*(years?|weeks?|days?|d|h|m|s)\b');

/// Parses `zellij list-sessions --no-formatting` output. Colours are
/// stripped too, so plain `list-sessions` output also works. "No active
/// zellij sessions found." (or empty output) gives an empty list.
List<ZellijSessionLine> parseZellijSessions(String out) {
  final res = <ZellijSessionLine>[];
  for (var line in const LineSplitter().convert(stripAnsi(out))) {
    line = line.trim();
    if (line.isEmpty || line.toLowerCase().startsWith('no active zellij sessions')) continue;
    final m = _lineRe.firstMatch(line);
    if (m == null) {
      // `--short` output or an unknown format: the first word is the name.
      final name = line.split(RegExp(r'\s+')).first;
      res.add(ZellijSessionLine(name: name, current: line.contains('(current)'), exited: line.contains('EXITED')));
      continue;
    }
    final rest = m.group(3)!;
    res.add(ZellijSessionLine(
      name: m.group(1)!,
      createdAgo: parseZellijDuration(m.group(2)!),
      current: rest.contains('(current)'),
      exited: rest.contains('EXITED'),
    ));
  }
  return res;
}

/// Parses zellij's age text (`13days 15h 3m 59s`, `1h 45m 46s`, `5s`).
Duration? parseZellijDuration(String s) {
  var secs = 0;
  var any = false;
  for (final m in _durRe.allMatches(s)) {
    any = true;
    final n = int.parse(m.group(1)!);
    final u = m.group(2)!;
    secs += switch (u[0]) {
      'y' => n * 365 * 86400,
      'w' => n * 7 * 86400,
      'd' => n * 86400,
      'h' => n * 3600,
      'm' => n * 60,
      _ => n,
    };
  }
  return any ? Duration(seconds: secs) : null;
}

/// Parses `zellij action list-panes --json` output, keeping terminal panes
/// only (plugins such as the tab bar are dropped). Invalid JSON gives [].
List<ZellijPane> parseZellijPanes(String json) {
  final Object? data;
  try {
    data = jsonDecode(json.trim());
  } on FormatException {
    return const [];
  }
  if (data is! List) return const [];
  final res = <ZellijPane>[];
  for (final p in data) {
    if (p is! Map) continue;
    if (p['is_plugin'] == true) continue;
    res.add(ZellijPane(
      id: (p['id'] as num?)?.toInt() ?? 0,
      title: p['title'] as String?,
      command: p['terminal_command'] as String?,
      exited: p['exited'] == true,
      focused: p['is_focused'] == true,
      tabName: p['tab_name'] as String?,
    ));
  }
  return res;
}

const _paneMarker = '@@agentd-app pane ';

class ZellijAdapter implements MuxAdapter {
  ZellijAdapter(this.shell, {required this.hostId, DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final RemoteShell shell;
  final String hostId;
  final DateTime Function() _now;

  @override
  SessionSource get source => SessionSource.zellij;

  /// The command used to list sessions.
  static const listCommand = 'zellij list-sessions --no-formatting';

  /// One script listing the panes of every running session in [names].
  static String panesCommand(Iterable<String> names) {
    final b = StringBuffer('for s in ${posixJoin(names)}; do ');
    b.write("printf '$_paneMarker%s\\n' \"\$s\"; ");
    b.write(r'zellij --session "$s" action list-panes --json --command --state 2>/dev/null; echo; done');
    return b.toString();
  }

  @override
  Future<List<AgentSession>> list({bool withPanes = true}) async {
    final r = await shell.exec(listCommand);
    checkInstalled('zellij', r);
    final text = '${r.stdout}\n${r.stderr}';
    if (!r.ok && !text.toLowerCase().contains('no active zellij sessions')) {
      if (r.stdout.trim().isEmpty) {
        throw MuxException('zellij list-sessions failed: ${r.stderr.trim()}', result: r);
      }
    }
    final lines = parseZellijSessions(r.stdout);
    var panes = <String, List<ZellijPane>>{};
    final live = [for (final l in lines) if (!l.exited) l.name];
    if (withPanes && live.isNotEmpty) {
      final p = await shell.exec(panesCommand(live));
      panes = parsePanesScript(p.stdout);
    }
    final now = _now();
    return [for (final l in lines) toSession(l, panes[l.name], now)];
  }

  /// Splits the output of [panesCommand] by session.
  static Map<String, List<ZellijPane>> parsePanesScript(String out) {
    final res = <String, List<ZellijPane>>{};
    String? cur;
    final buf = StringBuffer();
    void flush() {
      if (cur != null && buf.toString().trim().isNotEmpty) res[cur] = parseZellijPanes(buf.toString());
      buf.clear();
    }

    for (final line in const LineSplitter().convert(out)) {
      if (line.startsWith(_paneMarker)) {
        flush();
        cur = line.substring(_paneMarker.length).trim();
      } else {
        buf.writeln(line);
      }
    }
    flush();
    return res;
  }

  AgentSession toSession(ZellijSessionLine l, List<ZellijPane>? panes, DateTime now) {
    final split = splitSessionName(l.name);
    String? harness;
    final alive = panes?.where((p) => !p.exited).toList() ?? const <ZellijPane>[];
    // The focused pane first, then any other pane.
    final ordered = [...alive.where((p) => p.focused), ...alive.where((p) => !p.focused)];
    for (final p in ordered) {
      harness = guessHarness(p.command, title: p.title);
      if (harness != null) break;
    }
    harness ??= split.harness;
    final detail = <String>[
      if (l.current) 'current',
      if (l.exited) 'exited',
      if (panes != null) '${alive.length} ${alive.length == 1 ? 'pane' : 'panes'}',
    ];
    return AgentSession(
      hostId: hostId,
      source: SessionSource.zellij,
      name: l.name,
      harness: harness,
      project: split.project,
      status: l.exited ? AgentStatus.exited : AgentStatus.unknown,
      updatedAt: l.createdAgo == null ? null : now.subtract(l.createdAgo!),
      detail: detail.isEmpty ? null : detail.join(' · '),
    );
  }

  static String attachCommand(String name) => 'zellij attach ${posixQuote(name)}';

  @override
  Future<PtySession> attach(String name, {int cols = 80, int rows = 24}) =>
      shell.pty(command: attachCommand(name), cols: cols, rows: rows);

  /// Commands [launch] runs, in order.
  static List<String> launchCommands({required String session, required String cwd, required List<String> command, String? paneName}) {
    if (command.isEmpty) throw ArgumentError('empty command');
    final s = posixQuote(session);
    return [
      'zellij attach --create-background $s',
      'zellij --session $s action new-pane --cwd ${posixDir(cwd)}'
          '${paneName == null ? '' : ' --name ${posixQuote(paneName)}'} -- ${posixJoin(command)}',
    ];
  }

  @override
  Future<AgentSession> launch({required String session, required String cwd, required List<String> command, String? harness}) async {
    harness ??= guessHarness(command.join(' '));
    for (final c in launchCommands(session: session, cwd: cwd, command: command, paneName: harness)) {
      final r = await shell.exec(c);
      checkInstalled('zellij', r);
      if (!r.ok) throw MuxException('`$c` failed: ${r.stderr.trim()}', result: r);
    }
    return AgentSession(
      hostId: hostId,
      source: SessionSource.zellij,
      name: session,
      harness: harness,
      project: splitSessionName(session).project ?? baseName(cwd),
      cwd: cwd,
      updatedAt: _now(),
    );
  }

  @override
  Future<void> kill(String name) async {
    final q = posixQuote(name);
    // --force kills a running session first; deleting also drops the
    // resurrectable (EXITED) state.
    final r = await shell.exec('zellij delete-session --force $q');
    checkInstalled('zellij', r);
    if (!r.ok && !r.stderr.toLowerCase().contains('not found')) {
      throw MuxException('zellij delete-session failed: ${r.stderr.trim()}', result: r);
    }
  }
}
