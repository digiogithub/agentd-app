// Relay hosts in the real HostsRepository / AgentdClients, against the
// in-memory fake host (test/relay/fake_host.dart).

import 'dart:async';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/data/data.dart';
import 'package:agentd_app/src/relay/relay.dart';
import 'package:agentd_app/src/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import '../agentd/fake_daemon.dart';
import '../relay/fake_host.dart';
import 'fakes.dart';

class _NoDetect implements ProvisionService {
  @override
  Future<HostCapabilities> detect(RemoteShell shell) => throw StateError('no detect over the relay');

  @override
  Stream<ProvisionEvent> install(
    RemoteShell shell,
    HostCapabilities caps, {
    bool agentd = true,
    bool hcListener = true,
    bool mcp = true,
    Set<String> clis = const {},
  }) => const Stream.empty();

  @override
  List<String> plan(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) => const [];

  @override
  List<PlannedStep> planSteps(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) => const [];
}

void main() {
  late FakeRelayHost host;
  late MemoryHostStore store;
  late MemoryKeyStore keys;
  late SshHostsRepository repo;

  setUp(() {
    host = FakeRelayHost(label: 'Mi box');
    store = MemoryHostStore();
    keys = MemoryKeyStore();
    repo = SshHostsRepository(
      store: store,
      keys: keys,
      hostKeys: MemoryHostKeyStore(),
      provision: _NoDetect(),
      autoConnect: true,
      reconnectBackoff: const [Duration(milliseconds: 20)],
      connect: (c, {password}) => throw StateError('no SSH for relay hosts'),
      relay: RelayClient(dial: host.dial, handshakeTimeout: const Duration(seconds: 2)),
      relayPlatform: 'android',
    );
  });

  tearDown(() => repo.dispose());

  Future<HostStatus> statusOf(String id) async => (await repo.watch().first).firstWhere((h) => h.config.id == id);

  Future<HostConfig> pair({void Function(RelayPairPhase)? onPhase}) =>
      repo.pairRelay(host.inviteLink('0123456789abcdef').toString(), deviceName: 'Pixel', onPhase: onPhase);

  test('pairing saves a relay host (no secret in the config) and connects it', () async {
    final phases = <RelayPairPhase>[];
    final c = await pair(onPhase: phases.add);
    expect(phases, [RelayPairPhase.connecting, RelayPairPhase.waitingApproval]);
    expect(c.isRelay, isTrue);
    expect(c.id, 'mi-box');
    expect(c.name, 'Mi box');
    expect(c.host, 'relay.example');
    expect(c.relay!.route, host.route);
    expect(c.relay!.hostKey, b64url(host.key.public));
    expect(c.relay!.scope, RelayScope.operate);
    expect(c.canOperate, isTrue);
    expect(c.canAdmin, isFalse);
    expect(c.hasShell, isFalse);
    expect(host.hellos.first, containsPair('platform', 'android'));
    expect(host.hellos.first, containsPair('name', 'Pixel'));
    // Saved without the invite code or the private key.
    final json = store.hosts.single.toJson().toString();
    expect(json, isNot(contains(b64url(host.inviteLink('x').code))));
    final secret = await keys.readSecret(relayKeySlot(c.keyId!));
    expect(secret, isNotNull);
    expect(json, isNot(contains(secret!)));
    expect(c.relay!.deviceId, relayDeviceId(DhKey.fromPrivate(unb64url(secret)).public));
    // Round trip through JSON.
    final back = HostConfig.fromJson(store.hosts.single.toJson());
    expect(back.isRelay, isTrue);
    expect(back.relay!.sameAs(c.relay!), isTrue);

    await eventually(() => host.muxes.isNotEmpty);
    final h = await statusOf(c.id);
    expect(h.state, HostState.online);
    expect(agentdSocketOf(h), 'relay');
    expect(h.capabilities!.has('zellij'), isFalse);
  });

  test('AgentdClients dial relay hosts through the tunnel', () async {
    final daemon = FakeDaemon()
      ..answer('ls', {
        'sessions': [sessionInfoJson()],
      });
    host.onStream = (s) async => bridge(s, await daemon.dial());
    final c = await pair();
    final clients = AgentdClients(repo);
    await eventually(() => host.muxes.isNotEmpty);
    final agentd = await clients.forHost(c.id);
    expect(agentd, isNotNull);
    expect((await agentd!.ls()).single.name, 'claude@webapp');
    await clients.dispose();
  });

  test('a host with no shell refuses shell()', () async {
    final c = await pair();
    await expectLater(repo.shell(c.id), throwsA(isA<NoShellOverRelay>()));
    expect(describeConnectError(const NoShellOverRelay()), contains('relay'));
  });

  test('a dropped tunnel marks the host offline, then it reconnects', () async {
    await pair();
    await eventually(() => host.muxes.isNotEmpty);
    final states = <HostState>[];
    final sub = repo.watch().listen((l) => states.add(l.single.state));
    host.online = false;
    await host.dropTunnels();
    await eventually(() => states.contains(HostState.offline));
    host.online = true;
    await eventually(() => states.isNotEmpty && states.last == HostState.online && host.muxes.isNotEmpty);
    await sub.cancel();
  });

  test('host offline is reported clearly', () async {
    final c = await pair();
    await eventually(() => host.muxes.isNotEmpty);
    await repo.disconnect(c.id);
    host.online = false;
    await expectLater(repo.connect(c.id), throwsA(isA<RelayError>()));
    final h = await statusOf(c.id);
    expect(h.state, HostState.error);
    expect(h.error, contains('no está conectado al relay'));
  });

  test('the welcome refreshes the scope (a downgrade on the host)', () async {
    final c = await pair();
    await eventually(() => host.muxes.isNotEmpty);
    await repo.disconnect(c.id);
    host.devices.updateAll((_, d) => RelayDevice(id: d.id, scope: 'view', kind: d.kind));
    await repo.connect(c.id);
    final h = await statusOf(c.id);
    expect(h.config.relay!.scope, RelayScope.view);
    expect(h.config.canOperate, isFalse);
    expect(store.hosts.single.relay!.scope, RelayScope.view);
  });

  test('pairing again with the same host replaces it; remove deletes the key', () async {
    final c1 = await pair();
    final c2 = await pair();
    expect(c2.id, c1.id);
    expect(store.hosts, hasLength(1));
    await repo.remove(c1.id);
    expect(await keys.readSecret(relayKeySlot(c1.keyId!)), isNull);
    expect(store.hosts, isEmpty);
  });

  test('a bad link and a denial are clear errors', () async {
    await expectLater(repo.pairRelay('agentd://relay?v=1', deviceName: 'x'), throwsA(isA<InviteFormatError>()));
    expect(describeConnectError(const InviteFormatError('x')), 'Enlace de invitación no válido');
    host.approve = (_) async => false;
    Object? err;
    try {
      await pair();
    } catch (e) {
      err = e;
    }
    expect(err, isA<RelayError>());
    expect(describeConnectError(err!), 'El host rechazó el emparejamiento');
    expect(store.hosts, isEmpty);
  });
}
