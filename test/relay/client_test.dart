import 'dart:async';
import 'dart:typed_data';

import 'package:agentd_app/src/agentd/agentd.dart';
import 'package:agentd_app/src/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../agentd/fake_daemon.dart';
import 'fake_host.dart';

void main() {
  late FakeRelayHost host;
  late RelayClient client;

  setUp(() {
    host = FakeRelayHost();
    client = RelayClient(dial: host.dial, handshakeTimeout: const Duration(seconds: 2));
  });

  Future<(DhKey, RelayPaired)> pair({String id = '0123456789abcdef'}) async {
    final dev = DhKey.generate();
    final p = await client.pair(host.inviteLink(id), dev, name: 'pixel', platform: 'android');
    return (dev, p);
  }

  RelayTarget target(DhKey dev) =>
      RelayTarget(relayUrl: 'https://relay.example', route: host.route, hostKey: host.key.public, device: dev, name: 'pixel', platform: 'android');

  test('pairing: IKpsk2 hello, confirm, waits for approval, paired', () async {
    final approval = Completer<bool>();
    host.approve = (_) => approval.future;
    final dev = DhKey.generate();
    var pending = false;
    final f = client.pair(host.inviteLink('0123456789abcdef'), dev, name: 'pixel', platform: 'android', onPending: () => pending = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(pending, isTrue);
    expect(host.sawConfirm, isTrue);
    approval.complete(true);
    final p = await f;
    expect(p.host, 'box');
    expect(p.device.id, relayDeviceId(dev.public));
    expect(p.device.scope, 'operate');
    expect(host.hellos.single, {'v': 1, 'mode': 'pair', 'invite': '0123456789abcdef', 'name': 'pixel', 'platform': 'android'});
  });

  test('pairing denied by the host', () async {
    host.approve = (_) async => false;
    await expectLater(pair(), throwsA(isA<RelayError>().having((e) => e.failure, 'failure', RelayFailure.denied)));
  });

  test('a used invite is refused as a handshake failure', () async {
    await pair();
    host.invite('0123456789abcdef', code: Uint8List(32)); // same id, other code
    final dev = DhKey.generate();
    final stale = RelayInvite(
      relayUrl: 'https://relay.example',
      route: host.route,
      hostKey: host.key.public,
      id: 'ffffffffffffffff',
      code: Uint8List(32)..[0] = 1,
    );
    await expectLater(
      client.pair(stale, dev, name: 'x', platform: 'android'),
      throwsA(isA<RelayError>().having((e) => e.failure, 'failure', RelayFailure.handshake)),
    );
  });

  test('a wrong pinned host key fails the handshake', () async {
    final (dev, _) = await pair();
    final other = DhKey.generate();
    final t = RelayTarget(relayUrl: 'https://relay.example', route: host.route, hostKey: other.public, device: dev);
    // The host cannot read message 1 and closes.
    await expectLater(client.connect(t), throwsA(isA<RelayError>().having((e) => e.failure, 'failure', RelayFailure.handshake)));
  });

  test('host offline maps the 4404 close', () async {
    final (dev, _) = await pair();
    host.online = false;
    await expectLater(client.connect(target(dev)), throwsA(isA<RelayError>().having((e) => e.failure, 'failure', RelayFailure.hostOffline)));
  });

  test('an unknown device is refused with the host code', () async {
    await expectLater(
      client.connect(target(DhKey.generate())),
      throwsA(isA<RelayError>().having((e) => e.failure, 'failure', RelayFailure.refused).having((e) => e.code, 'code', 'forbidden')),
    );
  });

  test('connect: welcome carries the device; streams echo', () async {
    final (dev, _) = await pair();
    final t = await client.connect(target(dev));
    expect(t.welcome.device!.scope, 'operate');
    expect(t.welcome.host, 'box');
    expect(host.hellos.last['mode'], 'connect');
    final s = t.open();
    final got = s.stream.first;
    s.add([1, 2, 3]);
    expect(await got, [1, 2, 3]);
    await t.close();
  });

  test('AgentdClient runs unchanged over relay streams (ops, subscribe, attach)', () async {
    final (dev, _) = await pair();
    final daemon = FakeDaemon();
    daemon.answer('ping', {'version': '1.2.3', 'pid': 1, 'epoch': 'e1'});
    daemon.answer('ls', {
      'sessions': [sessionInfoJson()],
    });
    daemon.on('attach', (c) async {
      c.ok();
      c.bytes([0x44, 0, 0, 0, 2, 0x68, 0x69]); // D frame "hi"
    });
    host.onStream = (s) async => bridge(s, await daemon.dial());
    final dialer = RelayDialer(client, target(dev));
    final agentd = AgentdClient(dialer.open);
    expect((await agentd.ping()).version, '1.2.3');
    expect((await agentd.ls()).single.name, 'claude@webapp');
    final pty = await agentd.attach('claude@webapp', cols: 80, rows: 24, observe: true);
    expect(String.fromCharCodes(await pty.stream.first), 'hi');
    await pty.close();
    // One tunnel for all of it (plus the pairing one).
    expect(host.tunnels, 2);
    await dialer.close();
  });

  test('the dialer reopens a dropped tunnel', () async {
    final (dev, _) = await pair();
    final dialer = RelayDialer(client, target(dev));
    final s1 = await dialer.open();
    await host.dropTunnels();
    await s1.done;
    final s2 = await dialer.open();
    final got = s2.stream.first;
    s2.add([7]);
    expect(await got, [7]);
    expect(host.tunnels, 3); // pairing + two
    await dialer.close();
  });
}
