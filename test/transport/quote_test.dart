import 'dart:io';

import 'package:agentd_app/src/transport/quote.dart';
import 'package:agentd_app/src/transport/ssh_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shellQuote', () {
    test('safe words stay bare', () {
      expect(shellQuote('abc'), 'abc');
      expect(shellQuote('/tmp/agentd-1000/agentd.sock'), '/tmp/agentd-1000/agentd.sock');
      expect(shellQuote('codex@webapp'), 'codex@webapp');
    });

    test('empty and special strings are single-quoted', () {
      expect(shellQuote(''), "''");
      expect(shellQuote('a b'), "'a b'");
      expect(shellQuote(r'$HOME'), r"'$HOME'");
      expect(shellQuote("it's"), r"'it'\''s'");
      expect(shellQuote("'"), r"''\'''");
    });

    test('round-trips through a real sh', () async {
      const samples = ['', 'plain', 'a b', "it's", r'$(id) `x` ; | & > < * ? ~ \ "q"', "''", 'line\nbreak', 'ünï ✳'];
      for (final s in samples) {
        final r = await Process.run('sh', ['-c', 'printf %s ${shellQuote(s)}']);
        expect(r.exitCode, 0);
        expect(r.stdout, s, reason: 'sample ${shellQuote(s)}');
      }
    }, skip: Platform.isWindows);

    test('shellJoin quotes each word', () {
      expect(shellJoin(['zellij', 'attach', 'my session']), "zellij attach 'my session'");
    });
  });

  group('ptyCommand', () {
    test('login shell when no command', () {
      expect(ptyCommand(), 'sh -c ${shellQuote(r'exec "${SHELL:-sh}" -l')}');
    });

    test('exports env and runs the command through sh -lc', () async {
      final cmd = ptyCommand(command: r'printf "%s|%s" "$A" "$B"', env: {'A': "x y", 'B': "it's"});
      final r = await Process.run('sh', ['-c', cmd]);
      expect(r.stdout, "x y|it's");
    }, skip: Platform.isWindows);

    test('rejects bad env names', () {
      expect(() => ptyCommand(command: 'true', env: {'A B': '1'}), throwsArgumentError);
    });
  });
}
