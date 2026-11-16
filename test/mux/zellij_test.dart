import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/mux/mux.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_remote_shell.dart';

// Shape of zellij 0.44.3 `list-sessions --no-formatting` (trailing space on
// running sessions included).
const sample044 = '''
claude-radar [Created 13days 15h 3m 59s ago] (EXITED - attach to resurrect)
rectangular-pigeon [Created 11days 7h 51m 34s ago] (EXITED - attach to resurrect)
codex@webapp [Created 23h 12m 23s ago]
claude-agentd [Created 1h 45m 46s ago] (current)
''';

// Coloured output (plain `zellij ls`) of an older version.
const sampleColour = '\x1b[32;1mmain\x1b[m [Created \x1b[35;1m2days\x1b[m ago] \n'
    '\x1b[32;1mold\x1b[m [Created \x1b[35;1m5s\x1b[m ago] (\x1b[31;1mEXITED\x1b[m - attach to resurrect)\n';

const panesJson = '''
[
  {"id": 0, "is_plugin": true, "is_focused": false, "title": "tab-bar", "exited": false, "terminal_command": null, "tab_name": "Tab #1"},
  {"id": 0, "is_plugin": false, "is_focused": true, "title": "~/src/agentd", "exited": false, "terminal_command": "/home/u/.local/bin/claude --resume", "tab_name": "Tab #1"},
  {"id": 1, "is_plugin": false, "is_focused": false, "title": "bash", "exited": false, "terminal_command": null, "tab_name": "Tab #1"},
  {"id": 2, "is_plugin": false, "is_focused": false, "title": "old", "exited": true, "terminal_command": "make", "tab_name": "Tab #1"}
]
''';

void main() {
  final now = DateTime.utc(2026, 11, 15, 12);

  group('parseZellijSessions', () {
    test('0.44 no-formatting output', () {
      final s = parseZellijSessions(sample044);
      expect(s.map((e) => e.name), ['claude-radar', 'rectangular-pigeon', 'codex@webapp', 'claude-agentd']);
      expect(s[0].exited, isTrue);
      expect(s[0].createdAgo, const Duration(days: 13, hours: 15, minutes: 3, seconds: 59));
      expect(s[2].exited, isFalse);
      expect(s[2].current, isFalse);
      expect(s[3].current, isTrue);
      expect(s[3].createdAgo, const Duration(hours: 1, minutes: 45, seconds: 46));
    });

    test('colours are stripped', () {
      final s = parseZellijSessions(sampleColour);
      expect(s.map((e) => e.name), ['main', 'old']);
      expect(s[0].createdAgo, const Duration(days: 2));
      expect(s[1].exited, isTrue);
    });

    test('empty and "no active sessions"', () {
      expect(parseZellijSessions(''), isEmpty);
      expect(parseZellijSessions('No active zellij sessions found.\n'), isEmpty);
    });

    test('--short output', () {
      expect(parseZellijSessions('a\nb\n').map((e) => e.name), ['a', 'b']);
    });
  });

  test('parseZellijPanes keeps terminal panes', () {
    final p = parseZellijPanes(panesJson);
    expect(p, hasLength(3));
    expect(p.first.command, contains('claude'));
    expect(p.first.focused, isTrue);
    expect(p.last.exited, isTrue);
    expect(parseZellijPanes('error: unknown subcommand'), isEmpty);
  });

  group('ZellijAdapter', () {
    test('list maps sessions and panes', () async {
      final sh = FakeRemoteShell()
        ..on('list-sessions', const ExecResult(0, sample044, ''))
        ..on('list-panes', const ExecResult(0, '@@agentd-app pane codex@webapp\n[]\n\n@@agentd-app pane claude-agentd\n$panesJson\n', ''));
      final z = ZellijAdapter(sh, hostId: 'h1', clock: () => now);
      final list = await z.list();
      expect(sh.commands.first, 'zellij list-sessions --no-formatting');
      // Only running sessions are asked for their panes, in one exec.
      expect(sh.commands[1], contains('for s in codex@webapp claude-agentd;'));
      expect(list, hasLength(4));
      final radar = list[0];
      expect(radar.source, SessionSource.zellij);
      expect(radar.status, AgentStatus.exited);
      expect(radar.harness, 'claude');
      expect(radar.project, 'radar');
      expect(radar.updatedAt, now.subtract(const Duration(days: 13, hours: 15, minutes: 3, seconds: 59)));
      expect(list[1].harness, isNull);
      expect(list[2].harness, 'codex');
      expect(list[2].project, 'webapp');
      expect(list[2].detail, '0 panes');
      final cur = list[3];
      expect(cur.harness, 'claude');
      expect(cur.detail, 'current · 2 panes');
      expect(cur.key, 'h1/zellij/claude-agentd');
    });

    test('no sessions (exit 1, message on stderr) is empty', () async {
      final sh = FakeRemoteShell()..on('list-sessions', const ExecResult(1, '', 'No active zellij sessions found.\n'));
      expect(await ZellijAdapter(sh, hostId: 'h').list(), isEmpty);
      expect(sh.commands, hasLength(1));
    });

    test('not installed throws', () async {
      final sh = FakeRemoteShell()..on('list-sessions', const ExecResult(127, '', 'sh: 1: zellij: not found\n'));
      expect(ZellijAdapter(sh, hostId: 'h').list(), throwsA(isA<MuxException>()));
    });

    test('attach opens a PTY', () async {
      final sh = FakeRemoteShell();
      await ZellijAdapter(sh, hostId: 'h').attach('my session', cols: 100, rows: 30);
      expect(sh.ptys.single.command, "zellij attach 'my session'");
      expect(sh.ptys.single.cols, 100);
    });

    test('launch creates a background session and a pane', () async {
      final sh = FakeRemoteShell();
      final s = await ZellijAdapter(sh, hostId: 'h', clock: () => now).launch(session: 'claude@api', cwd: '~/src/api', command: ['claude', 'fix the "tests"']);
      expect(sh.commands, [
        'zellij attach --create-background claude@api',
        'zellij --session claude@api action new-pane --cwd "\$HOME"/src/api --name claude -- claude \'fix the "tests"\'',
      ]);
      expect(s.harness, 'claude');
      expect(s.project, 'api');
    });

    test('launch failure throws', () async {
      final sh = FakeRemoteShell()..on('new-pane', const ExecResult(1, '', 'boom'));
      expect(ZellijAdapter(sh, hostId: 'h').launch(session: 's', cwd: '/tmp', command: ['codex']), throwsA(isA<MuxException>()));
    });

    test('kill', () async {
      final sh = FakeRemoteShell();
      await ZellijAdapter(sh, hostId: 'h').kill('s1');
      expect(sh.commands, ['zellij kill-session s1', 'zellij delete-session --force s1']);
    });

    test('launch without a command opens the default shell pane', () async {
      final sh = FakeRemoteShell();
      await ZellijAdapter(sh, hostId: 'h').launch(session: 'api', cwd: '/srv/api', command: const []);
      expect(sh.commands.last, 'zellij --session api action new-pane --cwd /srv/api');
    });
  });
}
