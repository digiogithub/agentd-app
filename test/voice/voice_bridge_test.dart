import 'dart:async';

import 'package:agentd_app/src/car/car_hub.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/fakes/fake_repositories.dart';
import 'package:agentd_app/src/voice/voice_bridge.dart';
import 'package:agentd_app/src/voice/voice_controller.dart';
import 'package:agentd_app/src/voice/voice_port.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('agentd/voice.test');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final sent = <MethodCall>[];
  // What the next `listen` answers (default: silence).
  final listens = <Object? Function()>[];

  setUp(() {
    sent.clear();
    listens.clear();
    messenger.setMockMethodCallHandler(ch, (c) async {
      sent.add(c);
      if (c.method == 'listen') return listens.isEmpty ? {'error': 'timeout'} : listens.removeAt(0)();
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(ch, null));

  List<String> methods() => [for (final c in sent) c.method];
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  group('MethodChannelVoicePort', () {
    test('maps listen results and errors', () {
      VoiceHeard h(Object? r) => MethodChannelVoicePort.heardFrom(r);
      expect(h({'alts': ['agentes', 'agente']}).alts, ['agentes', 'agente']);
      expect(h({'alts': <Object?>[]}).error, 'no_match');
      for (final code in ['no_match', 'timeout', 'busy', 'audio', 'network', 'permission', 'other']) {
        expect(h({'error': code}).error, code);
      }
      expect(h({'error': 'recognizer_exploded'}).error, 'other');
      expect(h(null).error, 'other');
      expect(h('raro').error, 'other');
      expect(h({'error': 'timeout'}).isSilence, isTrue);
      expect(h({'error': 'permission'}).isSilence, isFalse);
    });

    test('sends say, listen, earcon, stopSpeaking, exit and state', () async {
      final port = MethodChannelVoicePort(ch)..headsetMic = false;
      listens.add(() => {'alts': ['hola']});
      await port.say('Hola');
      final heard = await port.listen(max: const Duration(seconds: 6));
      await port.earcon(Earcon.ok);
      await port.stopSpeaking();
      await port.state('Escuchando');
      await port.exit();
      expect(heard.alts, ['hola']);
      expect(methods(), ['say', 'listen', 'earcon', 'stopSpeaking', 'state', 'exit']);
      expect(sent[0].arguments, {'text': 'Hola'});
      expect(sent[1].arguments, {'maxMs': 6000, 'headsetMic': false});
      expect(sent[2].arguments, {'kind': 'ok'});
      expect(sent[4].arguments, {'text': 'Escuchando'});
    });

    test('platform failures never throw: listen is "other"', () async {
      messenger.setMockMethodCallHandler(ch, (c) async => throw PlatformException(code: c.method == 'say' ? 'tts' : 'boom'));
      final port = MethodChannelVoicePort(ch);
      await port.say('Hola');
      expect((await port.listen()).error, 'other');
      await port.earcon(Earcon.error);
      await port.exit();
    });

    test('listen waits for the listening tone (bounded)', () async {
      final tone = Completer<void>();
      messenger.setMockMethodCallHandler(ch, (c) async {
        sent.add(c);
        if (c.method == 'earcon') await tone.future;
        if (c.method == 'listen') return {'alts': ['sí']};
        return null;
      });
      final port = MethodChannelVoicePort(ch);
      unawaited(port.earcon(Earcon.listenStart));
      final heard = port.listen();
      await settle();
      expect(methods(), ['earcon']);
      tone.complete();
      expect((await heard).alts, ['sí']);
      expect(methods(), ['earcon', 'listen']);

      // A tone that is never answered does not block the listen for long.
      sent.clear();
      messenger.setMockMethodCallHandler(ch, (c) async {
        sent.add(c);
        if (c.method == 'earcon') return Completer<Object?>().future;
        return {'alts': ['no']};
      });
      unawaited(port.earcon(Earcon.listenStart));
      expect((await port.listen()).alts, ['no']);
    });
  });

  group('VoiceBridge', () {
    late CarHub hub;
    late VoiceBridge bridge;
    final made = <VoiceController>[];

    setUp(() {
      made.clear();
      hub = CarHub(
        hosts: FakeHostsRepository(hosts: const [HostStatus(HostConfig(id: 'h1', name: 'estudio', host: 'e', user: 'j'), state: HostState.online)]),
        sessions: FakeSessionsRepository(sessions: const []),
        board: FakeBoardRepository(boards: {'h1': const HostBoard(hostId: 'h1', sessions: [BoardSession(hostId: 'h1', name: 'codex@api')])}),
        debounce: Duration.zero,
        settleTimeout: const Duration(milliseconds: 200),
      );
      bridge = VoiceBridge(
        hub,
        channel: ch,
        headsetMic: () async => false,
        unplugGrace: const Duration(milliseconds: 40),
        controller: (port, hub) {
          final c = VoiceController(port: port, hub: hub);
          made.add(c);
          return c;
        },
      );
    });
    tearDown(() async {
      await bridge.handle(const MethodCall('stopped', <String, Object?>{}));
      await hub.dispose();
    });

    test('started creates and starts a controller; again while on keeps it', () async {
      expect(bridge.controller, isNull);
      await bridge.handle(const MethodCall('started', {'source': 'launcher'}));
      await settle();
      await bridge.controller!.whenIdle();
      expect(made, hasLength(1));
      expect(bridge.controller!.state, VoiceState.armed);
      expect(bridge.port.headsetMic, isFalse);
      expect(sent.firstWhere((c) => c.method == 'say').arguments, {'text': 'Modo voz. Pulsa para hablar.'});
      final states = [for (final c in sent) if (c.method == 'state') (c.arguments as Map)['text']];
      expect(states, containsAllInOrder(['Pulsa para hablar', 'Hablando', 'Pulsa para hablar']));

      await bridge.handle(const MethodCall('started', {'source': 'notification'}));
      expect(made, hasLength(1));
    });

    test('buttons reach the port; unknown keys are ignored', () async {
      final got = <VoiceButton>[];
      final sub = bridge.port.buttons.listen(got.add);
      await bridge.handle(const MethodCall('button', {'key': 'next'}));
      await bridge.handle(const MethodCall('button', {'key': 'playPause'}));
      await bridge.handle(const MethodCall('button', {'key': 'eject'}));
      await settle();
      expect(got, [VoiceButton.next, VoiceButton.playPause]);
      await sub.cancel();
      await bridge.handle(const MethodCall('route', {'bt': true}));
      await expectLater(bridge.handle(const MethodCall('nope')), throwsA(isA<MissingPluginException>()));
    });

    test('a button press talks to the running controller', () async {
      await bridge.handle(const MethodCall('started', {'source': 'app'}));
      await settle();
      await bridge.controller!.whenIdle();
      sent.clear();
      listens.add(() => {'alts': ['ayuda']});
      await bridge.handle(const MethodCall('button', {'key': 'playPause'}));
      await settle();
      await bridge.controller!.whenIdle();
      expect((sent.firstWhere((c) => c.method == 'listen').arguments as Map)['headsetMic'], isFalse);
      final states = [for (final c in sent) if (c.method == 'state') (c.arguments as Map)['text']];
      expect(states, containsAllInOrder(['Escuchando', 'Hablando']));
      expect((sent.firstWhere((c) => c.method == 'say').arguments as Map)['text'], startsWith('Puedes decir'));
    });

    test('stopped disposes the controller; a new start makes a new one', () async {
      await bridge.handle(const MethodCall('started', {'source': 'app'}));
      await settle();
      final first = bridge.controller!;
      await bridge.handle(const MethodCall('stopped', <String, Object?>{}));
      expect(bridge.controller, isNull);
      expect(first.state, VoiceState.off);

      await bridge.handle(const MethodCall('started', {'source': 'app'}));
      await settle();
      expect(made, hasLength(2));
      expect(bridge.controller, isNot(same(first)));
    });

    test('a controller that exited by itself is replaced on the next start', () async {
      await bridge.handle(const MethodCall('started', {'source': 'app'}));
      await settle();
      await bridge.controller!.whenIdle();
      listens.add(() => {'error': 'permission'});
      await bridge.handle(const MethodCall('button', {'key': 'playPause'}));
      await settle();
      await bridge.controller!.whenIdle();
      expect(methods(), contains('exit'));
      expect(bridge.controller!.state, VoiceState.off);
      await bridge.handle(const MethodCall('started', {'source': 'launcher'}));
      await settle();
      expect(made, hasLength(2));
      expect(bridge.controller!.state, isNot(VoiceState.off));
    });

    test('headphones gone for the grace time: off without a word, service told to exit', () async {
      await bridge.handle(const MethodCall('started', {'source': 'launcher'}));
      await settle();
      await bridge.controller!.whenIdle();
      sent.clear();
      // A short drop (profile switch while the mic opens) is ignored.
      await bridge.handle(const MethodCall('route', {'bt': false}));
      await bridge.handle(const MethodCall('route', {'bt': true}));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(bridge.controller, isNotNull);
      await bridge.handle(const MethodCall('route', {'bt': false}));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(bridge.controller, isNull);
      expect(sent.map((c) => c.method), contains('exit'));
      expect(sent.where((c) => c.method == 'say'), isEmpty);
    });

    test('stateText', () {
      expect(VoiceBridge.stateText(VoiceState.armed, 'codex@api'), 'Con codex@api · pulsa para hablar');
      expect(VoiceBridge.stateText(VoiceState.acting, null), isNull);
    });
  });
}
