import 'dart:io';

import 'package:agentd_app/src/provision/provision.dart';
import 'package:flutter_test/flutter_test.dart';

import '../mux/fake_remote_shell.dart';

import 'package:agentd_app/src/core/contracts.dart';

String section(String name, [String body = '']) =>
    '@@agentd-app $name\n${body.isEmpty ? '' : '$body\n'}';

final linuxFull = [
  section('os', 'Linux'),
  section('arch', 'x86_64'),
  section(
    'os-release',
    'PRETTY_NAME="Ubuntu 24.04.1 LTS"\nNAME="Ubuntu"\nVERSION_ID="24.04"\nID=ubuntu',
  ),
  section('macos'),
  section('uid', '1000'),
  section('home', '/home/u'),
  section('path', '/home/u/.local/bin:/usr/local/bin:/usr/bin:/bin'),
  section('runtime-dir', '/run/user/1000'),
  section('systemd', 'yes'),
  section(
    'tool agentd',
    'path=/home/u/.local/bin/agentd\nversion=agentd 0.4.0',
  ),
  section('tool zellij', 'path=/usr/bin/zellij\nversion=zellij 0.44.3'),
  section('tool tmux', 'path=/usr/bin/tmux\nversion=tmux 3.4'),
  section('tool node', 'path=/usr/bin/node\nversion=v22.11.0'),
  section('tool npm', 'path=/usr/bin/npm\nversion=10.9.0'),
  section(
    'tool claude',
    'path=/home/u/.local/bin/claude\nversion=2.0.76 (Claude Code)',
  ),
  section(
    'tool codex',
    'path=/home/u/.local/bin/codex\nversion=codex-cli 0.58.0',
  ),
  section(
    'tool pando',
    'path=/home/u/.local/bin/pando\nversion=pando version v1.4.2',
  ),
  section('tool opencode', 'path=/home/u/.local/bin/opencode\nversion=1.0.12'),
  section('tool gemini', 'path=/home/u/.local/bin/gemini\nversion=0.15.0'),
  section(
    'socket',
    'live=/run/user/1000/agentd/agentd.sock\nlive=/run/user/1000/agentd/agentd.sock\ndefault=/run/user/1000/agentd/agentd.sock',
  ),
  section('end'),
].join();

final macArm = [
  section('os', 'Darwin'),
  section('arch', 'arm64'),
  section('os-release'),
  section('macos', 'name=macOS\nversion=15.1'),
  section('uid', '501'),
  section('home', '/Users/u'),
  section('path', '/usr/bin:/bin:/usr/sbin:/sbin'),
  section('runtime-dir'),
  section('systemd', 'no'),
  section('tool agentd', 'path=/usr/local/bin/agentd\nversion=0.4.0'),
  section('tool zellij'),
  section('tool tmux', 'path=/opt/homebrew/bin/tmux\nversion=tmux next-3.6'),
  section('tool node'),
  section('tool npm'),
  section('tool claude'),
  section('tool codex'),
  section('tool pando'),
  section('tool opencode'),
  section('tool gemini'),
  section('socket', 'default=/tmp/agentd-501/agentd.sock'),
  section('end'),
].join();

final minimal = [
  section('os', 'Linux'),
  section('arch', 'aarch64'),
  section('os-release', 'NAME="Alpine Linux"\nID=alpine\nVERSION_ID=3.20.3'),
  section('macos'),
  section('uid', '1000'),
  section('home', '/home/u'),
  section('path', '/usr/bin:/bin'),
  section('runtime-dir'),
  section('systemd', 'no'),
  for (final t in detectTools.keys) section('tool $t'),
  section('socket', 'default=/tmp/agentd-1000/agentd.sock'),
  section('end'),
].join();

void main() {
  test('Linux amd64 with everything', () {
    final r = parseDetect(linuxFull);
    final c = r.capabilities;
    expect(r.complete, isTrue);
    expect(c.os, 'Linux');
    expect(c.arch, 'x86_64');
    expect(c.distro, 'Ubuntu 24.04.1 LTS');
    expect(c.systemdUser, isTrue);
    expect(c.runtimeDir, '/run/user/1000');
    expect(c.agentdSocket, '/run/user/1000/agentd/agentd.sock');
    expect(c.tools.keys.toSet(), detectTools.keys.toSet());
    expect(detectTools.keys.every(c.has), isTrue);
    expect(c.tools['agentd']!.version, '0.4.0');
    expect(c.tools['agentd']!.path, '/home/u/.local/bin/agentd');
    expect(c.tools['node']!.version, '22.11.0');
    expect(c.tools['claude']!.version, '2.0.76');
    expect(c.tools['codex']!.version, '0.58.0');
    expect(c.tools['pando']!.version, '1.4.2');
    expect(c.tools['tmux']!.version, '3.4');
    expect(r.localBinOnPath, isTrue);
  });

  test('macOS arm64', () {
    final r = parseDetect(macArm);
    final c = r.capabilities;
    expect(c.os, 'Darwin');
    expect(c.arch, 'arm64');
    expect(c.distro, 'macOS 15.1');
    expect(c.systemdUser, isFalse);
    expect(c.runtimeDir, isNull);
    // agentd installed, daemon not running: where it will listen.
    expect(c.agentdSocket, '/tmp/agentd-501/agentd.sock');
    expect(c.has('zellij'), isFalse);
    expect(c.tools['tmux']!.version, '3.6');
    expect(r.localBinOnPath, isFalse);
  });

  test('minimal host without systemd (CRLF too)', () {
    final c = parseDetect(minimal.replaceAll('\n', '\r\n')).capabilities;
    expect(c.os, 'Linux');
    expect(c.arch, 'aarch64');
    expect(c.distro, 'Alpine Linux 3.20.3');
    expect(c.systemdUser, isFalse);
    expect(c.agentdSocket, isNull);
    expect(c.tools.values.any((t) => t.installed), isFalse);
  });

  test('cleanVersion', () {
    expect(cleanVersion('zellij 0.44.3'), '0.44.3');
    expect(cleanVersion('v1.2.3-rc.1'), '1.2.3-rc.1');
    expect(cleanVersion('weird'), 'weird');
    expect(cleanVersion(''), isNull);
  });

  test('detect runs the script once and fails on garbage', () async {
    final sh = FakeRemoteShell()
      ..on('@@agentd-app', ExecResult(0, linuxFull, ''));
    final c = await const DefaultProvisionService().detect(sh);
    expect(c.has('agentd'), isTrue);
    expect(sh.commands.single, detectScript);
    final bad = FakeRemoteShell(
      fallback: const ExecResult(1, '', 'sh: syntax error'),
    );
    expect(
      const DefaultProvisionService().detect(bad),
      throwsA(isA<ProvisionException>()),
    );
  });

  // Runs the real script with /bin/sh in a sandbox: HOME is a temp dir and
  // PATH holds only fake tools plus the few utilities the script uses, so
  // no real CLI is ever started. One fake tool hangs to exercise the 5 s
  // limit, once with `timeout` on PATH and once through the shell watchdog
  // (hosts without timeout/gtimeout, e.g. stock macOS; the sandbox has no
  // mktemp either, so the $HOME fallback temp file is used and must go).
  for (final withTimeout in [true, false]) {
  test('detect script runs under sh with fake tools (${withTimeout ? 'timeout' : 'watchdog'})', () async {
    final tmp = await Directory.systemTemp.createTemp('agentd-app-detect');
    addTearDown(() => tmp.delete(recursive: true));
    final bin = Directory('${tmp.path}/bin')..createSync();
    for (final u in ['uname', 'cat', 'sed', 'id', 'sleep', 'grep', 'rm', if (withTimeout) 'timeout']) {
      final p = [
        '/usr/bin/$u',
        '/bin/$u',
      ].firstWhere((x) => File(x).existsSync(), orElse: () => '');
      if (p.isNotEmpty) Link('${bin.path}/$u').createSync(p);
    }
    void fake(String name, String body) {
      final f = File('${bin.path}/$name')
        ..writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('chmod', ['755', f.path]);
    }

    fake('zellij', 'echo "zellij 0.44.3"');
    fake('node', 'echo v22.11.0');
    fake('claude', 'echo "2.0.76 (Claude Code)"');
    fake('gemini', 'sleep 30');
    final sock = '${tmp.path}/run/agentd';
    Directory(sock).createSync(recursive: true);
    final sw = Stopwatch()..start();
    final r = await Process.run(
      '/bin/sh',
      ['-c', detectScript],
      environment: {
        'HOME': tmp.path,
        'PATH': bin.path,
        'XDG_RUNTIME_DIR': '${tmp.path}/run',
      },
      includeParentEnvironment: false,
    );
    sw.stop();
    expect(r.exitCode, 0, reason: r.stderr as String);
    final rep = parseDetect(r.stdout as String);
    expect(rep.complete, isTrue);
    final c = rep.capabilities;
    expect(c.os, Platform.isMacOS ? 'Darwin' : 'Linux');
    expect(c.tools['zellij']!.version, '0.44.3');
    expect(c.tools['zellij']!.path, '${bin.path}/zellij');
    expect(c.tools['claude']!.version, '2.0.76');
    expect(c.has('gemini'), isTrue);
    expect(c.tools['gemini']!.version, isNull);
    expect(c.has('tmux'), isFalse);
    expect(c.has('agentd'), isFalse);
    expect(c.systemdUser, isFalse);
    expect(c.runtimeDir, '${tmp.path}/run');
    // The sandbox has no socket; a real daemon of this uid may still be
    // found at /run/user/<uid> (a fallback the script also checks).
    expect(
      c.agentdSocket == null || c.agentdSocket!.startsWith('/run/user/'),
      isTrue,
    );
    expect(rep.defaultSocket, '${tmp.path}/run/agentd/agentd.sock');
    final left = tmp.listSync().where((e) => e.path.split('/').last.startsWith('.agentd-app-run5.'));
    expect(left, isEmpty, reason: 'watchdog temp files left');
    expect(sw.elapsed, lessThan(const Duration(seconds: 20)));
  }, timeout: const Timeout(Duration(seconds: 60)));
  }
}
