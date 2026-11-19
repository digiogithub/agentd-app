// The WebSocket transport against a loopback relay stand-in (dart:io server
// that upgrades /v1/connect and hands the socket to the fake host), plus an
// optional test against a real agentd-relay.

import 'dart:async';
import 'dart:io';

import 'package:agentd_app/src/agentd/agentd.dart';
import 'package:agentd_app/src/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_host.dart';

void main() {
  late HttpServer server;
  late FakeRelayHost host;
  late String base;
  final seenPaths = <String>[];

  setUp(() async {
    host = FakeRelayHost();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      seenPaths.add(req.uri.toString());
      if (req.uri.path != '/v1/connect') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req, protocolSelector: (p) => p.contains(relaySubprotocol) ? relaySubprotocol : null);
      if (!host.online || req.uri.queryParameters['route'] != host.route) {
        await ws.close(4404, 'host offline');
        return;
      }
      host.tunnels++;
      unawaited(host.serve(WsMsgConn(ws)));
    });
  });

  tearDown(() => server.close(force: true));

  RelayClient client() => RelayClient(dial: (u, r) => WsMsgConn.dialTunnel(u, r, timeout: const Duration(seconds: 3)));

  test('pair then connect over a real WebSocket', () async {
    final dev = DhKey.generate();
    final inv = RelayInvite(relayUrl: base, route: host.route, hostKey: host.key.public, id: '0123456789abcdef', code: host.invite('0123456789abcdef'));
    final p = await client().pair(inv, dev, name: 'pixel', platform: 'android');
    expect(p.device.id, relayDeviceId(dev.public));
    final t = await client().connect(RelayTarget(relayUrl: base, route: host.route, hostKey: host.key.public, device: dev));
    final s = t.open();
    final got = s.stream.first;
    s.add('hello'.codeUnits);
    expect(String.fromCharCodes(await got), 'hello');
    await t.close();
    expect(seenPaths.last, '/v1/connect?route=${host.route}');
  });

  test('4404 from the relay is host offline', () async {
    host.online = false;
    final t = RelayTarget(relayUrl: base, route: host.route, hostKey: host.key.public, device: DhKey.generate());
    await expectLater(client().connect(t), throwsA(isA<RelayError>().having((e) => e.failure, 'failure', RelayFailure.hostOffline)));
  });

  test('nothing listening is unreachable', () async {
    final port = server.port;
    await server.close(force: true);
    final t = RelayTarget(relayUrl: 'http://127.0.0.1:$port', route: host.route, hostKey: host.key.public, device: DhKey.generate());
    await expectLater(client().connect(t), throwsA(isA<RelayError>().having((e) => e.failure, 'failure', RelayFailure.unreachable)));
  });

  // Against a running agentd-relay + daemon: AGENTD_RELAY_TEST_INVITE = a
  // link from `agentd relay invite --no-approve --scope admin` (a throwaway
  // daemon and a loopback relay; the test starts and removes a `sh` session).
  final link = Platform.environment['AGENTD_RELAY_TEST_INVITE'];
  test('real relay: pair, connect, ops, attach, run/kill/rm', () async {
    final inv = RelayInvite.parse(link!);
    final dev = DhKey.generate();
    final paired = await RelayClient().pair(inv, dev, name: 'agentd-app test', platform: 'android');
    expect(paired.device.id, relayDeviceId(dev.public));
    final dialer = RelayDialer(RelayClient(), RelayTarget(relayUrl: inv.relayUrl, route: inv.route, hostKey: inv.hostKey, device: dev));
    final c = AgentdClient(dialer.open);
    expect((await c.ping()).version, isNotEmpty);
    expect((await dialer.tunnel()).welcome.device!.id, paired.device.id);
    const name = 'sh@agentd-app-relay-test';
    final info = await c.run(target: '/tmp', harness: 'sh', name: name);
    expect(info.name, name);
    expect((await c.ls()).map((s) => s.name), contains(name));
    final pty = await c.attach(name, observe: true);
    expect(await pty.stream.first.timeout(const Duration(seconds: 10)), isNotEmpty);
    await pty.close();
    await c.kill(name, signal: 'KILL');
    for (var i = 0; i < 50 && (await c.ls()).any((s) => s.name == name && s.state != 'exited'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await c.rm(name);
    expect((await c.ls()).map((s) => s.name), isNot(contains(name)));
    await dialer.close();
  }, skip: link == null ? 'set AGENTD_RELAY_TEST_INVITE to run against a real relay' : false);
}
