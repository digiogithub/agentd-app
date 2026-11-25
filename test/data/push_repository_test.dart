// Push registrations over the fake daemon: ops push_register /
// push_unregister, and the cases where a host cannot take them.

import 'package:agentd_app/src/agentd/agentd.dart';
import 'package:agentd_app/src/data/data.dart';
import 'package:flutter_test/flutter_test.dart';

import '../agentd/fake_daemon.dart';
import 'fakes.dart';

void main() {
  late FakeDaemon d;
  late AgentdPushRepository repo;

  setUp(() {
    d = FakeDaemon();
    final hosts = StubHosts([onlineHost('h', testCaps()), onlineHost('plain', testCaps(agentd: false))], {'h': DataShell(daemon: d)});
    repo = AgentdPushRepository(clients: AgentdClients(hosts), platform: 'android');
  });

  test('client: push_register and push_unregister send exactly the daemon args', () async {
    final c = AgentdClient(d.dial, timeout: const Duration(seconds: 2));
    d.answer('push_register', {'id': 'p0123456789ab'});
    d.answer('push_unregister', {'removed': 1});
    expect(await c.pushRegister(token: 'tok', platform: 'android', name: 'Pixel', hostRef: 'h1'), 'p0123456789ab');
    expect(d.lastArgs('push_register'), {'token': 'tok', 'platform': 'android', 'name': 'Pixel', 'host_ref': 'h1'});
    expect(await c.pushRegister(token: 'tok', platform: 'android', name: 'Pixel'), 'p0123456789ab');
    expect(d.lastArgs('push_register'), {'token': 'tok', 'platform': 'android', 'name': 'Pixel'});
    expect(await c.pushUnregister(token: 'tok'), 1);
    expect(d.lastArgs('push_unregister'), {'token': 'tok'});
  });

  test('register gives the saved host id as host_ref and caps the name', () async {
    d.answer('push_register', {'id': 'p1'});
    expect(await repo.register('h', token: 'tok', deviceName: 'x' * 80), isTrue);
    expect(d.lastArgs('push_register'), {'token': 'tok', 'platform': 'android', 'name': 'x' * 64, 'host_ref': 'h'});
  });

  test('an older daemon, a refusal or a host without agentd is false, never an error', () async {
    d.on('push_register', (c) => c.fail('unknown op "push_register"', code: 'invalid'));
    expect(await repo.register('h', token: 'tok', deviceName: 'Pixel'), isFalse);
    d.on('push_register', (c) => c.fail('guests cannot', code: 'forbidden'));
    expect(await repo.register('h', token: 'tok', deviceName: 'Pixel'), isFalse);
    expect(await repo.register('plain', token: 'tok', deviceName: 'Pixel'), isFalse);
    expect(await repo.register('gone', token: 'tok', deviceName: 'Pixel'), isFalse);
    d.on('push_unregister', (c) => c.fail('unknown op "push_unregister"', code: 'invalid'));
    await repo.unregister('h', token: 'tok');
    await repo.unregister('gone', token: 'tok');
  });
}
