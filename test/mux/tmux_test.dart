import 'dart:io';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/mux/mux.dart';
import 'package:agentd_app/src/mux/quote.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_remote_shell.dart';

const sessions = 'main\t3\t1\t1763200000\t1763100000\t/home/u\n'
    'codex@webapp\t1\t0\t1763201000\t1763101000\t/home/u/src/webapp\n'
    'work\t2\t0\t1763202000\t1763102000\t\n';

const panes = 'main\t0\t0\t0\t0\tbash\t/home/u\tu@box\t0\n'
    'main\t1\t0\t1\t1\t2.0.76\t/home/u/src/agentd\t✳ Claude Code\t0\n'
    'main\t2\t0\t1\t0\tvim\t/home/u\tvim\t0\n'
    'codex@webapp\t0\t0\t1\t1\tnode\t/home/u/src/webapp\tcodex\t0\n'
    'work\t0\t0\t1\t1\tpando\t/srv/api\tpando\t1\n';

void main() {
  test('parseTmuxSessions', () {
    final s = parseTmuxSessions(sessions);
    expect(s.map((e) => e.name), ['main', 'codex@webapp', 'work']);
    expect(s[0].windows, 3);
    expect(s[0].attached, 1);
    expect(s[0].activity, DateTime.fromMillisecondsSinceEpoch(1763200000 * 1000, isUtc: true));
    expect(s[2].path, isNull);
    // Older tmux without session_created/session_path: missing fields.
    final old = parseTmuxSessions('a\t1\t0\t1763200000\n');
    expect(old.single.created, isNull);
    expect(parseTmuxSessions(''), isEmpty);
    // Octal-escaped separators.
    expect(parseTmuxSessions(r'x\0112\0110\0111763200000').single.windows, 2);
  });

  test('parseTmuxPanes', () {
    final p = parseTmuxPanes(panes);
    expect(p, hasLength(5));
    expect(p[1].command, '2.0.76');
    expect(p[1].active && p[1].windowActive, isTrue);
    expect(p.last.dead, isTrue);
  });

  group('TmuxAdapter', () {
    test('list maps sessions with harness guesses', () async {
      final sh = FakeRemoteShell()
        ..on('list-sessions', const ExecResult(0, sessions, ''))
        ..on('list-panes', const ExecResult(0, panes, ''));
      final list = await TmuxAdapter(sh, hostId: 'h').list();
      expect(sh.commands[0], "tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}\t#{session_created}\t#{session_path}'");
      expect(sh.commands[1], startsWith("tmux list-panes -a -F '#{session_name}\t"));
      expect(sh.commands[1], contains('#{pane_current_command}'));
      final main = list[0];
      expect(main.source, SessionSource.tmux);
      expect(main.harness, 'claude'); // version-named native binary
      expect(main.cwd, '/home/u/src/agentd');
      expect(main.project, 'agentd');
      expect(main.detail, '3 windows · 3 panes · attached');
      expect(list[1].harness, 'codex'); // node, resolved by the title
      expect(list[1].project, 'webapp');
      expect(list[2].status, AgentStatus.exited);
      expect(list[2].harness, isNull); // dead pane ignored
    });

    for (final err in ['no server running on /tmp/tmux-1000/default', 'error connecting to /tmp/tmux-1000/default (No such file or directory)']) {
      test('"$err" is empty', () async {
        final sh = FakeRemoteShell()..on('list-sessions', ExecResult(1, '', '$err\n'));
        expect(await TmuxAdapter(sh, hostId: 'h').list(), isEmpty);
      });
    }

    test('other failure and missing tmux throw', () async {
      final sh = FakeRemoteShell()..on('list-sessions', const ExecResult(1, '', 'unknown option'));
      expect(TmuxAdapter(sh, hostId: 'h').list(), throwsA(isA<MuxException>()));
      final sh2 = FakeRemoteShell()..on('list-sessions', const ExecResult(127, '', 'sh: tmux: command not found'));
      expect(TmuxAdapter(sh2, hostId: 'h').list(), throwsA(isA<MuxException>()));
    });

    test('attach', () async {
      final sh = FakeRemoteShell();
      await TmuxAdapter(sh, hostId: 'h').attach('main', cols: 120, rows: 40);
      expect(sh.ptys.single.command, 'tmux attach-session -t =main');
      expect(sh.ptys.single.rows, 40);
    });

    test('launch without a command opens the default shell', () async {
      final sh = FakeRemoteShell();
      await TmuxAdapter(sh, hostId: 'h').launch(session: 'api', cwd: '/srv/api', command: const []);
      expect(
        sh.commands.single,
        'if tmux has-session -t =api 2>/dev/null; '
        'then tmux new-window -t =api: -c /srv/api; '
        'else tmux new-session -d -s api -c /srv/api; fi',
      );
    });

    test('launch', () async {
      final sh = FakeRemoteShell();
      final s = await TmuxAdapter(sh, hostId: 'h').launch(session: 'codex@api', cwd: '/srv/my api', command: ['codex', "it's"]);
      final cmd = posixQuote(posixJoin(['codex', "it's"]));
      expect(
        sh.commands.single,
        'if tmux has-session -t =codex@api 2>/dev/null; '
        "then tmux new-window -t =codex@api: -n codex -c '/srv/my api' $cmd; "
        "else tmux new-session -d -s codex@api -n codex -c '/srv/my api' $cmd; fi",
      );
      expect(s.harness, 'codex');
      expect(s.project, 'api');
    });

    test('kill tolerates a missing session', () async {
      final sh = FakeRemoteShell()..on('kill-session', const ExecResult(1, '', "can't find session: x"));
      await TmuxAdapter(sh, hostId: 'h').kill('x');
      expect(sh.commands.single, 'tmux kill-session -t =x');
    });
  });

  test('posixQuote round-trips through sh', () async {
    const words = ['plain', 'with space', "it's", r'$HOME `x` "q"', '', 'a\nb', '*'];
    final r = await Process.run('sh', ['-c', 'for a in ${posixJoin(words)}; do printf "[%s]" "\$a"; done']);
    expect(r.stdout, words.map((w) => '[$w]').join());
    final nested = await Process.run('sh', ['-c', 'sh -c ${posixQuote(posixJoin(['printf', '%s', "it's"]))}']);
    expect(nested.stdout, "it's");
  });

  group('guessHarness', () {
    test('commands', () {
      expect(guessHarness('claude'), 'claude');
      expect(guessHarness('/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js'), 'claude');
      expect(guessHarness('node /usr/bin/codex'), 'codex');
      expect(guessHarness('2.1.3'), 'claude');
      expect(guessHarness('node'), isNull);
      expect(guessHarness('node', title: 'gemini'), 'gemini');
      expect(guessHarness('bash'), isNull);
      expect(guessHarness(null), isNull);
    });

    test('session names', () {
      expect(splitSessionName('codex@webapp'), (harness: 'codex', project: 'webapp'));
      expect(splitSessionName('claude-agentd'), (harness: 'claude', project: 'agentd'));
      expect(splitSessionName('pando'), (harness: 'pando', project: null));
      expect(splitSessionName('rectangular-pigeon'), (harness: null, project: null));
    });
  });
}
