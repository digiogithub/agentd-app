// DevicesRepository over the fake daemon: op relay devices / revoke.

import 'package:agentd_app/src/agentd/agentd.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/data/data.dart';
import 'package:flutter_test/flutter_test.dart';

import '../agentd/fake_daemon.dart';
import 'fakes.dart';

Map<String, Object?> deviceJson(String id, String name, {String scope = 'operate', String kind = 'owner', bool online = false, List<String>? sessions, String? platform, bool guestExpiry = false}) => {
  'id': id,
  'name': name,
  'platform': ?platform,
  'scope': scope,
  'sessions': ?sessions,
  'kind': kind,
  'created_at': '2026-11-20T10:00:00Z',
  if (guestExpiry) 'expires_at': '2026-12-01T10:00:00Z',
  if (!online) 'last_seen': '2026-11-24T09:00:00Z',
  if (online) 'online': true,
};

void main() {
  late FakeDaemon d;
  late StubHosts hosts;
  late AgentdClients clients;
  late AgentdDevicesRepository repo;

  // 'h' is an SSH host; 'r' carries this app's relay device id.
  setUp(() {
    d = FakeDaemon();
    final relayHost = HostStatus(
      const HostConfig(
        id: 'r',
        name: 'r',
        host: 'r.local',
        user: 'u',
        relay: RelayHostInfo(relayUrl: 'https://relay.example', route: 'x', hostKey: 'k', deviceId: 'dme', scope: RelayScope.operate, kind: 'owner'),
      ),
      state: HostState.online,
      capabilities: testCaps(),
    );
    hosts = StubHosts([onlineHost('h', testCaps()), relayHost], {'h': DataShell(daemon: d), 'r': DataShell(daemon: d)});
    clients = AgentdClients(hosts);
    repo = AgentdDevicesRepository(hosts: hosts, clients: clients);
    d.answer('relay', {
      'enabled': true,
      'devices': [
        deviceJson('dzeta', 'Zeta', platform: 'linux'),
        deviceJson('dguest', 'iPad', scope: 'view', kind: 'guest', sessions: ['claude@docs'], platform: 'ios', guestExpiry: true),
        deviceJson('dme', 'Pixel', online: true, platform: 'android'),
        deviceJson('dmac', 'MacBook', scope: 'admin', online: true),
      ],
      'invites': [
        {'id': '0123456789abcdef', 'scope': 'view', 'kind': 'owner', 'expires_at': '2026-11-24T12:00:00Z', 'state': 'waiting'},
      ],
    });
  });

  tearDown(() => clients.dispose());

  test('wire: relay devices and revoke send exactly the daemon args', () async {
    final c = AgentdClient(d.dial);
    final list = await c.relayDevices();
    expect(d.lastArgs('relay'), {'action': 'devices'});
    expect(list.map((x) => x.id), ['dzeta', 'dguest', 'dme', 'dmac']);
    final g = list[1];
    expect((g.name, g.platform, g.scope, g.kind, g.online), ('iPad', 'ios', 'view', 'guest', false));
    expect(g.sessions, ['claude@docs']);
    expect((g.createdAt, g.expiresAt, g.lastSeen), (DateTime.utc(2026, 11, 20, 10), DateTime.utc(2026, 12, 1, 10), DateTime.utc(2026, 11, 24, 9)));
    expect((list[2].online, list[2].lastSeen, list[2].expiresAt), (true, null, null));
    await c.relayRevoke('dzeta');
    expect(d.lastArgs('relay'), {'action': 'revoke', 'device': 'dzeta'});
    // A host without devices answers without the field.
    d.answer('relay', {'enabled': false});
    expect(await c.relayDevices(), isEmpty);
  });

  test('over SSH every device is listed; none is this app', () async {
    final list = await repo.devices('h');
    expect(list.map((x) => x.id), ['dmac', 'dme', 'dguest', 'dzeta'], reason: 'connected first, then by name');
    expect(list.any((x) => x.isThisDevice), isFalse);
    final g = list.firstWhere((x) => x.id == 'dguest');
    expect((g.guest, g.scope, g.platform, g.expiresAt), (true, RelayScope.view, 'ios', DateTime.utc(2026, 12, 1, 10)));
    expect(g.sessions, ['claude@docs']);
  });

  test('on a relay host this device is marked and listed first', () async {
    final list = await repo.devices('r');
    expect(list.first.id, 'dme');
    expect(list.where((x) => x.isThisDevice).map((x) => x.id), ['dme']);
  });

  test('revoking another device keeps the host; revoking this one removes it', () async {
    await repo.revoke('r', 'dzeta');
    expect(d.lastArgs('relay'), {'action': 'revoke', 'device': 'dzeta'});
    expect(hosts.removed, isEmpty);
    await repo.revoke('r', 'dme');
    expect(d.lastArgs('relay'), {'action': 'revoke', 'device': 'dme'});
    expect(hosts.removed, ['r']);
    // Over SSH the same id is just another device.
    hosts.removed.clear();
    await repo.revoke('h', 'dme');
    expect(hosts.removed, isEmpty);
  });

  test('refusals map to the contract; a failed self revoke keeps the host', () async {
    for (final (code, failure) in [('forbidden', DevicesFailure.forbidden), ('not_found', DevicesFailure.notFound), ('invalid', DevicesFailure.unavailable)]) {
      d.on('relay', (c) => c.fail('refused', code: code));
      await expectLater(repo.devices('h'), throwsA(isA<DevicesException>().having((e) => e.failure, 'failure', failure)));
      await expectLater(repo.revoke('r', 'dme'), throwsA(isA<DevicesException>().having((e) => e.failure, 'failure', failure)));
    }
    expect(hosts.removed, isEmpty);
    await expectLater(repo.devices('nope'), throwsA(isA<DevicesException>().having((e) => e.failure, 'failure', DevicesFailure.unavailable)));
  });

  test('who may manage devices', () {
    HostConfig relay(RelayScope scope, {String kind = 'owner', List<String> sessions = const []}) => HostConfig(
      id: 'x',
      name: 'x',
      host: 'r',
      user: '',
      transport: HostTransport.relay,
      relay: RelayHostInfo(relayUrl: 'https://r.example', route: 'r', hostKey: 'k', deviceId: 'd', scope: scope, kind: kind, sessions: sessions),
    );
    expect(const HostConfig(id: 'x', name: 'x', host: 'h', user: 'u').canManageDevices, isTrue);
    expect(relay(RelayScope.admin).canManageDevices, isTrue);
    expect(relay(RelayScope.operate).canManageDevices, isFalse);
    expect(relay(RelayScope.admin, kind: 'guest').canManageDevices, isFalse);
    expect(relay(RelayScope.admin, sessions: ['claude@*']).canManageDevices, isFalse);
  });
}
