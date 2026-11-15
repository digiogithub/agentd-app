import 'dart:io';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/provision/provision.dart';
import 'package:flutter_test/flutter_test.dart';

import '../mux/fake_remote_shell.dart';

HostCapabilities caps({bool systemd = true, Set<String> tools = const {}}) => HostCapabilities(
      os: 'Linux',
      arch: 'x86_64',
      systemdUser: systemd,
      tools: {for (final t in tools) t: ToolInfo(t, installed: true, path: '/usr/bin/$t')},
    );

const svc = DefaultProvisionService();

void main() {
  group('plan', () {
    test('fresh host, everything', () {
      final steps = svc.planSteps(caps(tools: {'node', 'npm'}), clis: {'claude', 'codex', 'pando', 'gemini', 'opencode'});
      expect(steps.map((s) => s.step), [
        ProvisionStep.download,
        ProvisionStep.verify,
        ProvisionStep.install,
        ProvisionStep.hcListener,
        ProvisionStep.service,
        ProvisionStep.cli,
        ProvisionStep.cli,
        ProvisionStep.cli,
        ProvisionStep.cli,
        ProvisionStep.cli,
        ProvisionStep.mcp,
        ProvisionStep.mcp,
        ProvisionStep.mcp,
      ]);
      final cmds = svc.plan(caps(tools: {'node', 'npm'}), clis: {'claude', 'codex', 'pando', 'gemini', 'opencode'});
      expect(cmds, steps.map((s) => s.command).toList());
      expect(cmds[0], contains('curl -fsSL -o "\$d/install.sh" https://github.com/digiogithub/agentd/releases/latest/download/install.sh'));
      expect(cmds[0], contains('releases/latest/download/SHA256SUMS'));
      expect(cmds[1], contains('sha256sum'));
      expect(cmds[1], contains('shasum -a 256'));
      expect(cmds[2], contains('sh "\$d/install.sh"'));
      expect(cmds[3], contains('listen = true'));
      expect(cmds[3], contains('agentd hc server start --json'));
      expect(cmds[4], contains('systemctl --user enable --now agentd'));
      expect(cmds[4], contains('systemctl --user daemon-reload'));
      expect(cmds[5], contains('npm install -g @anthropic-ai/claude-code'));
      expect(cmds[5], contains('npm install -g --prefix "\$HOME/.local" @anthropic-ai/claude-code'));
      expect(cmds[6], contains('@openai/codex'));
      expect(cmds[7], contains('https://raw.githubusercontent.com/digiogithub/pando/main/scripts/install.sh'));
      expect(cmds[7], contains('--no-desktop --cli-only'));
      expect(cmds[8], contains('opencode-ai'));
      expect(cmds[9], contains('@google/gemini-cli'));
      expect(cmds[10], contains('claude mcp add --scope user agentd -- "\$a" mcp'));
      expect(cmds[11], contains('[mcp_servers.agentd]'));
      expect(cmds[12], contains('[MCPServers.agentd]'));
    });

    test('installed agentd and CLIs are not reinstalled', () {
      final steps = svc.planSteps(caps(tools: {'agentd', 'claude', 'npm'}), clis: {'claude'});
      expect(steps.map((s) => s.step), [ProvisionStep.hcListener, ProvisionStep.service, ProvisionStep.mcp]);
    });

    test('no systemd: the daemon is started by the CLI', () {
      final steps = svc.planSteps(caps(systemd: false), hcListener: false, mcp: false);
      expect(steps.last.step, ProvisionStep.service);
      expect(steps.last.command, contains('"\$a" ls >/dev/null'));
      expect(steps.last.command, isNot(contains('systemctl')));
    });

    test('nothing selected', () {
      expect(svc.plan(caps(tools: {'agentd'}), agentd: false, hcListener: false, mcp: false), isEmpty);
    });

    test('every script is valid POSIX sh', () async {
      final all = [detectScript, ...svc.plan(caps(), clis: installableClis.toSet()), ...svc.plan(caps(systemd: false))];
      for (final c in all) {
        final r = await Process.run('sh', ['-n', '-c', c]);
        expect(r.exitCode, 0, reason: '${r.stderr}\n$c');
      }
    });
  });

  group('install', () {
    test('event sequence with a failing step', () async {
      final sh = FakeRemoteShell()
        ..on('releases/latest/download/install.sh', const ExecResult(0, 'downloaded install.sh and SHA256SUMS to /c\n', ''))
        ..on('SHA256SUMS")', const ExecResult(1, '', 'checksum mismatch for install.sh\n'))
        ..on('@anthropic-ai/claude-code', const ExecResult(0, 'added 3 packages\n/home/u/.local/bin/claude\n', ''));
      final events = await svc.install(sh, caps(tools: {'npm'}), clis: {'claude'}).toList();
      String fmt(ProvisionEvent e) => '${e.step.name}:${e.skipped ? 'skipped' : e.error != null ? 'error' : e.done ? 'done' : 'start'}';
      expect(events.map(fmt), [
        'download:start',
        'download:done',
        'verify:start',
        'verify:error',
        'install:skipped', // same group
        'hcListener:skipped', // needs agentd
        'service:skipped',
        'cli:start',
        'cli:done', // independent of agentd
        'mcp:skipped', // needs agentd
      ]);
      expect(events[1].message, 'downloaded install.sh and SHA256SUMS to /c');
      expect(events[3].error, contains('checksum mismatch'));
      expect(events[3].error, startsWith('exit 1'));
      expect(events[4].skipped, isTrue);
      expect(events[4].error, isNull);
      expect(events[8].message, '/home/u/.local/bin/claude');
      // Skipped steps never ran.
      expect(sh.commands, hasLength(3));
    });

    test('all succeed; an exec exception is an error event', () async {
      final sh = FakeRemoteShell(fallback: const ExecResult(0, 'ok\n', ''))..onThrow('claude mcp', StateError('connection lost'));
      final events = await svc.install(sh, caps(tools: {'agentd', 'claude'})).toList();
      expect(events.where((e) => e.done).map((e) => e.step), [ProvisionStep.hcListener, ProvisionStep.service]);
      expect(events.last.step, ProvisionStep.mcp);
      expect(events.last.error, contains('connection lost'));
      expect(sh.commands, svc.plan(caps(tools: {'agentd', 'claude'})));
    });
  });

  // The config-editing scripts run for real under sh in a sandbox HOME with
  // a fake `agentd` that only answers `hc server status` as "no daemon".
  group('scripts in a sandbox', () {
    late Directory home;
    late Map<String, String> env;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('agentd-app-prov');
      final bin = Directory('${home.path}/.local/bin')..createSync(recursive: true);
      final a = File('${bin.path}/agentd')..writeAsStringSync('#!/bin/sh\nexit 2\n');
      Process.runSync('chmod', ['755', a.path]);
      env = {'HOME': home.path, 'PATH': '/usr/bin:/bin', 'XDG_CONFIG_HOME': '${home.path}/.config'};
    });
    tearDown(() => home.delete(recursive: true));

    Future<ProcessResult> run(String script) => Process.run('/bin/sh', ['-c', script], environment: env, includeParentEnvironment: false);
    String step(ProvisionStep k, {String? contains}) =>
        svc.planSteps(caps(tools: {'agentd', 'claude', 'codex', 'pando'})).firstWhere((s) => s.step == k && (contains == null || s.command.contains(contains))).command;
    File cfg() => File('${home.path}/.config/agentd/config.toml');

    test('hc listener: new file, then idempotent', () async {
      final s = step(ProvisionStep.hcListener);
      var r = await run(s);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, contains('appended [herdr] listen = true'));
      expect(r.stdout, contains('agentd daemon not running'));
      expect(cfg().readAsStringSync(), '\n[herdr]\nlisten = true\n');
      r = await run(s);
      expect(r.stdout, contains('kept [herdr] listen = true'));
      expect(cfg().readAsStringSync(), '\n[herdr]\nlisten = true\n');
    });

    test('hc listener: inserts into an existing [herdr] table', () async {
      cfg()
        ..createSync(recursive: true)
        ..writeAsStringSync('[run]\nlog_max_mb = 10\n\n[herdr]  # compat\nread_only = true\n\n[acl]\n"x" = ["*"]\n');
      final r = await run(step(ProvisionStep.hcListener));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(cfg().readAsStringSync(), '[run]\nlog_max_mb = 10\n\n[herdr]  # compat\nlisten = true\nread_only = true\n\n[acl]\n"x" = ["*"]\n');
    });

    test('hc listener: an explicit listen = false is kept', () async {
      const body = '[herdr]\nlisten = false # off on purpose\n';
      cfg()
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
      final r = await run(step(ProvisionStep.hcListener));
      expect(r.stdout, contains('kept [herdr] listen = false'));
      expect(cfg().readAsStringSync(), body);
    });

    test('hc listener: other tables only, [herdr.x] does not count', () async {
      cfg()
        ..createSync(recursive: true)
        ..writeAsStringSync('[herdr.extra]\nlisten = false\n');
      await run(step(ProvisionStep.hcListener));
      expect(cfg().readAsStringSync(), '[herdr.extra]\nlisten = false\n\n[herdr]\nlisten = true\n');
    });

    test('codex and pando MCP registration, idempotent', () async {
      final codex = step(ProvisionStep.mcp, contains: 'codex');
      final pando = step(ProvisionStep.mcp, contains: 'MCPServers');
      for (var i = 0; i < 2; i++) {
        expect((await run(codex)).exitCode, 0);
        expect((await run(pando)).exitCode, 0);
      }
      final a = '${home.path}/.local/bin/agentd';
      expect(File('${home.path}/.codex/config.toml').readAsStringSync(), '\n[mcp_servers.agentd]\ncommand = "$a"\nargs = ["mcp"]\n');
      expect(File('${home.path}/.pando.toml').readAsStringSync(), "\n[MCPServers.agentd]\nType = 'stdio'\nCommand = '$a'\nArgs = ['mcp']\n");
    });

    test('pando MCP refuses to shadow a .pando.json', () async {
      File('${home.path}/.pando.json').writeAsStringSync('{}');
      final r = await run(step(ProvisionStep.mcp, contains: 'MCPServers'));
      expect(r.exitCode, 1);
      expect(File('${home.path}/.pando.toml').existsSync(), isFalse);
    });
  });
}
