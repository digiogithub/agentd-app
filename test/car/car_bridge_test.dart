import 'package:agentd_app/src/car/car_bridge.dart';
import 'package:agentd_app/src/car/car_hub.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/fakes/fake_repositories.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('agentd/car.test');

  late FakeBoardRepository board;
  late CarBridge bridge;
  final sent = <MethodCall>[];

  setUp(() {
    sent.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
      sent.add(c);
      return null;
    });
    board = FakeBoardRepository(boards: {
      'h1': const HostBoard(hostId: 'h1', sessions: [
        BoardSession(hostId: 'h1', name: 'codex@api', questions: [AgentQuestion(id: 5, body: '¿Sigo?', options: ['Sí', 'No'])]),
      ]),
    });
    final hub = CarHub(
      hosts: FakeHostsRepository(hosts: const [HostStatus(HostConfig(id: 'h1', name: 'estudio', host: 'e', user: 'j'), state: HostState.online)]),
      sessions: FakeSessionsRepository(sessions: const []),
      board: board,
      debounce: Duration.zero,
      settleTimeout: const Duration(milliseconds: 200),
    );
    bridge = CarBridge(hub, ch);
  });

  test('start says ready, then sends the snapshot and the notices', () async {
    bridge.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent.first.method, 'ready');
    expect(sent.map((c) => c.method), containsAll(['snapshot', 'notify']));
    expect((sent.firstWhere((c) => c.method == 'notify').arguments as Map)['tag'], 'q/h1/5');
  });

  test('reply goes through the hub; refusals are Spanish PlatformExceptions', () async {
    bridge.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await bridge.handle(const MethodCall('reply', {'key': 'h1/agentd/codex@api', 'text': 'no'})), 'Respondido a codex@api: No');
    expect(board.calls.single.arg, 'No');
    await expectLater(
      bridge.handle(const MethodCall('reply', {'key': 'h1/agentd/nadie', 'text': 'hola'})),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'refused').having((e) => e.message, 'message', 'Ese agente ya no está')),
    );
    await expectLater(bridge.handle(const MethodCall('answer', {'hostId': 'h1'})), throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'bad_args')));
  });
}
