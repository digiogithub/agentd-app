import 'dart:async';
import 'dart:io';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/data/data.dart';
import 'package:agentd_app/src/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _Detect implements ProvisionService {
  _Detect(this.caps);
  final HostCapabilities caps;
  int detects = 0;
  Object? error;

  @override
  Future<HostCapabilities> detect(RemoteShell shell) async {
    detects++;
    if (error != null) throw error!;
    return caps;
  }

  @override
  Stream<ProvisionEvent> install(RemoteShell shell, HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) =>
      const Stream.empty();

  @override
  List<String> plan(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) => const [];

  @override
  List<PlannedStep> planSteps(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) => const [];
}

void main() {
  late MemoryHostStore store;
  late MemoryKeyStore keys;
  late MemoryHostKeyStore hostKeys;
  late _Detect detect;
  late List<(HostConfig, String?)> connects;
  late DataShell shell;
  Object? connectError;

  SshHostsRepository repo({bool auto = false}) => SshHostsRepository(
    store: store,
    keys: keys,
    hostKeys: hostKeys,
    provision: detect,
    autoConnect: auto,
    connect: (c, {password}) async {
      connects.add((c, password));
      if (connectError != null) throw connectError!;
      // What SshConnector does on a newly trusted key.
      if (c.hostKeyFingerprint == null && await hostKeys.get(c.id) == null) await hostKeys.put(c.id, 'SHA256:newkey');
      return shell;
    },
  );

  const cfg = HostConfig(id: 'mini', name: 'mini', host: '10.0.0.5', user: 'ana');

  setUp(() {
    store = MemoryHostStore();
    keys = MemoryKeyStore();
    hostKeys = MemoryHostKeyStore();
    detect = _Detect(testCaps(zellij: true));
    connects = [];
    shell = DataShell();
    connectError = null;
  });

  test('save persists, connect detects and records the TOFU fingerprint', () async {
    final r = repo();
    final seen = <List<HostStatus>>[];
    final sub = r.watch().listen(seen.add);
    await r.save(cfg);
    expect(store.hosts.single.id, 'mini');
    await r.connect('mini');
    await eventually(() => seen.isNotEmpty && seen.last.single.state == HostState.online);
    final h = seen.last.single;
    expect(h.capabilities!.has('zellij'), isTrue);
    expect(h.config.hostKeyFingerprint, 'SHA256:newkey');
    expect(store.hosts.single.hostKeyFingerprint, 'SHA256:newkey');
    expect(detect.detects, 1);
    // shell() reuses the pooled connection.
    expect(await r.shell('mini'), same(shell));
    expect(connects, hasLength(1));
    await sub.cancel();
    await r.dispose();
  });

  test('a failed connect is an error state with a Spanish message', () async {
    final r = repo();
    await r.save(cfg);
    connectError = HostKeyMismatch(hostId: 'mini', expected: 'SHA256:a', actual: 'SHA256:b');
    await expectLater(r.connect('mini'), throwsA(isA<HostKeyMismatch>()));
    final h = (await r.watch().first).single;
    expect(h.state, HostState.error);
    expect(h.error, contains('huella del host cambió'));
    await r.dispose();
  });

  test('saved hosts load and auto-connect on first watch', () async {
    store.hosts = [cfg];
    final r = repo(auto: true);
    final sub = r.watch().listen((_) {});
    await eventually(() => connects.isNotEmpty);
    await eventually(() => detect.detects == 1);
    await sub.cancel();
    await r.dispose();
  });

  test('remove forgets the host and its trusted key', () async {
    final r = repo();
    await r.save(cfg);
    await r.connect('mini');
    await r.remove('mini');
    expect(store.hosts, isEmpty);
    expect(await hostKeys.get('mini'), isNull);
    expect(await r.watch().first, isEmpty);
    await r.dispose();
  });

  test('password bootstrap installs the key and switches to key auth', () async {
    shell.on('authorized_keys', const ExecResult(0, 'added\n', ''));
    final r = repo();
    final saved = await r.enrollWithPassword(cfg.copyWith(auth: AuthKind.password), 'hunter2');
    final (used, password) = connects.single;
    expect(used.auth, AuthKind.password);
    expect(password, 'hunter2');
    expect(shell.commands.single, installAuthorizedKeyScript);
    expect(shell.stdins.single, '${await keys.ensureGeneratedKey()}\n');
    expect(shell.isClosed, isTrue);
    expect(saved.auth, AuthKind.generatedKey);
    expect(saved.keyId, isNull);
    expect(saved.hostKeyFingerprint, 'SHA256:newkey');
    expect(store.hosts.single.auth, AuthKind.generatedKey);
    // Never stored: not in the host config, not in the secure store.
    expect(store.hosts.single.toJson().values, isNot(contains('hunter2')));
    expect(await keys.password('mini'), isNull);
    expect(await keys.password(defaultKeyId), isNull);
    await r.dispose();
  });

  test('password bootstrap reports a failed install', () async {
    shell.on('authorized_keys', const ExecResult(1, '', 'mkdir: permission denied'));
    final r = repo();
    await expectLater(r.enrollWithPassword(cfg, 'pw'), throwsA(isA<EnrollError>().having((e) => e.message, 'message', contains('permission denied'))));
    expect(store.hosts, isEmpty);
    await r.dispose();
  });

  group('authorized_keys script under sh', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('agentd-app-ak'));
    tearDown(() => home.deleteSync(recursive: true));

    Future<ProcessResult> run(String key) async {
      final p = await Process.start('/bin/sh', ['-c', installAuthorizedKeyScript], environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'});
      p.stdin.write('$key\n');
      await p.stdin.close();
      final out = await p.stdout.transform(const SystemEncoding().decoder).join();
      final err = await p.stderr.transform(const SystemEncoding().decoder).join();
      return ProcessResult(p.pid, await p.exitCode, out, err);
    }

    const key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyBlob agentd-app';

    test('creates ~/.ssh with safe modes and appends once', () async {
      final r1 = await run(key);
      expect(r1.exitCode, 0, reason: r1.stderr as String);
      expect((r1.stdout as String).trim(), 'added');
      final r2 = await run(key.replaceFirst('agentd-app', 'other-comment'));
      expect((r2.stdout as String).trim(), 'present');
      final f = File('${home.path}/.ssh/authorized_keys');
      expect(f.readAsLinesSync(), [key]);
      expect(Directory('${home.path}/.ssh').statSync().modeString(), 'rwx------');
      expect(f.statSync().modeString(), 'rw-------');
    });

    test('keeps existing keys and a missing final newline', () async {
      Directory('${home.path}/.ssh').createSync();
      final f = File('${home.path}/.ssh/authorized_keys')..writeAsStringSync('ssh-rsa AAAAold old');
      final r = await run(key);
      expect(r.exitCode, 0, reason: r.stderr as String);
      expect(f.readAsLinesSync(), ['ssh-rsa AAAAold old', key]);
    });

    test('refuses something that is not a public key', () async {
      final r = await run('-----BEGIN OPENSSH PRIVATE KEY-----');
      expect(r.exitCode, 2);
      expect(File('${home.path}/.ssh/authorized_keys').existsSync(), isFalse);
    });
  });
}
