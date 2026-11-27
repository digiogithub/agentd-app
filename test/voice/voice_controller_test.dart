import 'dart:async';

import 'package:agentd_app/src/car/car_hub.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/fakes/fake_repositories.dart';
import 'package:agentd_app/src/voice/voice_controller.dart';
import 'package:agentd_app/src/voice/voice_port.dart';
import 'package:flutter_test/flutter_test.dart';

// Host id `estudio`: the fake repository offers its sample aliases as
// projects (webapp, api, agentd, docs, pips).
const _host = HostConfig(id: 'estudio', name: 'estudio', host: 'estudio.local', user: 'jose');
const _apiKey = 'estudio/agentd/codex@api';
const _webKey = 'estudio/agentd/claude@webapp';

AgentSession _api() => AgentSession(hostId: 'estudio', source: SessionSource.agentd, name: 'codex@api', status: AgentStatus.waiting, updatedAt: DateTime(2026, 11, 25, 9));

AgentSession _web({bool menu = false}) => AgentSession(
      hostId: 'estudio',
      source: SessionSource.agentd,
      name: 'claude@webapp',
      status: menu ? AgentStatus.waiting : AgentStatus.working,
      pending: menu
          ? const PendingInteraction(
              question: 'Do you want to run npm run lint?',
              kind: PendingKind.permission,
              revision: 7,
              epoch: 'e1',
              options: [SessionOption(id: 'o1', label: 'Yes', index: 1), SessionOption(id: 'o2', label: 'No', index: 2)],
            )
          : null,
      updatedAt: DateTime(2026, 11, 25, 10),
    );

HostBoard _board({bool question = false}) => HostBoard(hostId: 'estudio', sessions: [
      BoardSession(
        hostId: 'estudio',
        name: 'codex@api',
        status: AgentStatus.waiting,
        questions: [
          if (question) AgentQuestion(id: 41, body: '¿Migro en caliente?', options: const ['Migración en caliente', 'Ventana de mantenimiento'], createdAt: DateTime(2026, 11, 25, 9)),
        ],
      ),
      const BoardSession(hostId: 'estudio', name: 'claude@webapp', status: AgentStatus.working),
    ]);

/// A scripted headset: what it will hear, what it said, its buttons.
class FakeVoicePort implements VoicePort {
  final heard = <VoiceHeard>[];
  final said = <String>[];
  final earcons = <Earcon>[];
  final listens = <Duration>[];
  int stops = 0;
  int exits = 0;

  /// Speech that stays "playing" until [stopSpeaking].
  bool Function(String text)? hold;
  Completer<void>? _speaking;
  final _buttons = StreamController<VoiceButton>.broadcast();

  void hear(List<String> alts) => heard.add(VoiceHeard(alts));
  void silence() => heard.add(const VoiceHeard.error('timeout'));
  void press(VoiceButton b) => _buttons.add(b);

  @override
  Future<void> say(String text) {
    said.add(text);
    if (hold?.call(text) ?? false) {
      _speaking = Completer<void>();
      return _speaking!.future;
    }
    return Future.value();
  }

  @override
  Future<VoiceHeard> listen({Duration max = const Duration(seconds: 8)}) async {
    listens.add(max);
    return heard.isEmpty ? const VoiceHeard.error('timeout') : heard.removeAt(0);
  }

  @override
  Future<void> earcon(Earcon kind) async => earcons.add(kind);

  @override
  Future<void> stopSpeaking() async {
    stops++;
    _speaking?.complete();
    _speaking = null;
  }

  @override
  Stream<VoiceButton> get buttons => _buttons.stream;

  @override
  Future<void> exit() async => exits++;
}

class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

/// Timers of a test: the short notice delay runs for real, the idle timeout
/// is fired by hand.
VoiceTimerFactory _timers([void Function(_FakeTimer)? onFake]) => (d, cb) {
      if (d < const Duration(seconds: 1)) return Timer(d, cb);
      final t = _FakeTimer(d, cb);
      onFake?.call(t);
      return t;
    };

void main() {
  late FakeHostsRepository hosts;
  late FakeSessionsRepository sessions;
  late FakeBoardRepository board;
  late CarHub hub;
  late FakeVoicePort port;
  late VoiceController voice;
  late List<_FakeTimer> timers;

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  Future<void> build({bool question = false, bool menu = false, HostConfig host = _host}) async {
    hosts = FakeHostsRepository(hosts: [HostStatus(host, state: HostState.online)]);
    sessions = FakeSessionsRepository(sessions: [_api(), _web(menu: menu)]);
    board = FakeBoardRepository(boards: {'estudio': _board(question: question)});
    hub = CarHub(hosts: hosts, sessions: sessions, board: board, debounce: Duration.zero, viewTimeout: const Duration(milliseconds: 200), settleTimeout: const Duration(milliseconds: 200));
    port = FakeVoicePort();
    timers = [];
    voice = VoiceController(port: port, hub: hub, timer: _timers((t) => timers.add(t)), noticeDelay: const Duration(milliseconds: 5));
    await voice.start();
    await settle();
    await voice.whenIdle();
    port.said.clear();
    port.earcons.clear();
  }

  tearDown(() async {
    await voice.dispose();
    await hub.dispose();
  });

  Future<void> press([VoiceButton b = VoiceButton.playPause]) async {
    port.press(b);
    await settle();
    await voice.whenIdle();
  }

  test('starts armed and greets', () async {
    hosts = FakeHostsRepository(hosts: const [HostStatus(_host, state: HostState.online)]);
    sessions = FakeSessionsRepository(sessions: [_api()]);
    board = FakeBoardRepository(boards: {'estudio': _board()});
    hub = CarHub(hosts: hosts, sessions: sessions, board: board, debounce: Duration.zero);
    port = FakeVoicePort();
    voice = VoiceController(port: port, hub: hub, timer: _timers(), noticeDelay: const Duration(milliseconds: 5));
    await voice.start();
    await voice.whenIdle();
    expect(port.said.first, 'Modo voz. Pulsa para hablar.');
    expect(voice.state, VoiceState.armed);
  });

  test('no microphone permission: says so and exits', () async {
    await build();
    port.heard.add(const VoiceHeard.error('permission'));
    await press();
    expect(port.said, ['Necesito permiso de micrófono.']);
    expect(port.exits, 1);
    expect(voice.state, VoiceState.off);
  });

  test('an answer is read back and sent only after "sí"', () async {
    await build(question: true);
    // The open question was announced; the press reads it.
    port
      ..hear(['opción dos'])
      ..hear(['sí, envía']);
    await press();
    expect(port.said[0], contains('¿Migro en caliente?'));
    expect(port.said[1], 'A codex de api: «Ventana de mantenimiento». ¿Envío?');
    expect(port.said[2], 'Respondido a codex@api: Ventana de mantenimiento');
    expect(board.calls.single.arg, 'Ventana de mantenimiento');
    expect(port.listens, const [Duration(seconds: 6), Duration(seconds: 10), Duration(seconds: 6)]);
    expect(port.earcons, containsAllInOrder([Earcon.listenStart, Earcon.listenEnd, Earcon.ok]));
    expect(voice.state, VoiceState.armed);
  });

  test('"no" cancels and silence cancels: nothing is sent', () async {
    await build();
    port
      ..hear(['api'])
      ..hear(['dicta usa la rama main'])
      ..hear(['no']);
    await press();
    expect(port.said, contains('A codex de api: «usa la rama main». ¿Envío?'));
    expect(port.said, contains('Cancelado.'));

    port
      ..hear(['responde espera'])
      ..silence();
    await press();
    expect(port.said.last, 'Cancelado.');
    expect(sessions.calls, isEmpty);
    expect(board.calls, isEmpty);
  });

  test('"repite" dictates again before sending', () async {
    await build();
    port
      ..hear(['api'])
      ..hear(['dicta'])
      ..hear(['haz los tests'])
      ..hear(['repite'])
      ..hear(['haz los tests de pagos'])
      ..hear(['sí']);
    await press();
    expect(port.said, containsAllInOrder(['Dicta.', 'A codex de api: «haz los tests». ¿Envío?', 'Dicta de nuevo.', 'A codex de api: «haz los tests de pagos». ¿Envío?', 'Instrucción enviada a codex@api']));
    expect(sessions.calls.single.method, 'prompt');
    expect(sessions.calls.single.arg, 'haz los tests de pagos');
  });

  test('a doubt between yes and no asks again, then cancels', () async {
    await build();
    port
      ..hear(['api'])
      ..hear(['dicta borra la base'])
      ..hear(['sí', 'no'])
      ..hear(['patata']);
    await press();
    expect(port.said.where((s) => s.endsWith('¿Envío?')), hasLength(2));
    expect(port.said, contains('Cancelado.'));
    expect(sessions.calls, isEmpty);
  });

  test('silence reprompts once, then back to armed', () async {
    await build();
    await press();
    expect(port.said, ['¿Sí?']);
    expect(port.listens, hasLength(2));
    expect(port.earcons.where((e) => e == Earcon.listenStart), hasLength(2));
    expect(voice.state, VoiceState.armed);
  });

  test('play/pause while speaking cuts the speech and listens (barge-in)', () async {
    await build();
    port
      ..hold = ((t) => t.startsWith('2 agentes'))
      ..hear(['agentes']);
    port.press(VoiceButton.playPause);
    await settle();
    expect(voice.state, VoiceState.speaking);
    expect(port.said.single, startsWith('2 agentes.'));
    port.hear(['ayuda']);
    port.press(VoiceButton.playPause);
    await settle();
    await voice.whenIdle();
    expect(port.stops, 1);
    // A full listen after the cut, not the short follow-up.
    expect(port.listens.sublist(0, 2), const [Duration(seconds: 8), Duration(seconds: 8)]);
    expect(port.said[1], startsWith('Puedes decir'));
  });

  test('next repeats the last thing said', () async {
    await build();
    port.hear(['agentes']);
    await press();
    final list = port.said.single;
    await press(VoiceButton.next);
    expect(port.said.last, list);
  });

  test('launch asks "¿Seguro?" and launches on yes', () async {
    await build();
    port
      ..hear(['nuevo agente en webapp con codex'])
      ..hear(['sí']);
    await press();
    expect(port.said, containsAllInOrder(['¿Seguro? Nuevo codex en webapp de estudio.', 'Lanzado codex en webapp.']));
    final c = sessions.calls.singleWhere((c) => c.method == 'launch');
    expect(c.session, 'codex@webapp');
    expect(voice.current, 'estudio/agentd/codex@webapp');

    port
      ..hear(['lanza docs'])
      ..hear(['no']);
    await press();
    expect(port.said.last, 'Cancelado.');
    expect(sessions.calls.where((c) => c.method == 'launch'), hasLength(1));
  });

  test('launch in an unknown project names the projects', () async {
    await build();
    port.hear(['nuevo agente en zanahoria']);
    await press();
    expect(port.said.first, startsWith('No conozco ese proyecto. Proyectos: webapp, api'));
    expect(sessions.calls, isEmpty);
  });

  test('stop asks "¿Seguro?" and sends Esc', () async {
    await build();
    port
      ..hear(['para api'])
      ..hear(['seguro']);
    await press();
    expect(port.said, containsAllInOrder(['¿Seguro? Paro a codex de api.', 'Parado codex de api.']));
    expect(sessions.calls.single.method, 'interrupt');
    expect(sessions.calls.single.session, 'codex@api');
  });

  test('a view-only host refuses answers and stops, nothing is sent', () async {
    await build(
      question: true,
      host: const HostConfig(id: 'estudio', name: 'estudio', host: '', user: '', transport: HostTransport.relay, relay: RelayHostInfo(relayUrl: 'wss://r', route: 'r', hostKey: 'k', deviceId: 'd')),
    );
    // No announcement: view-only devices get no notices.
    expect(port.said, isEmpty);
    port
      ..hear(['api'])
      ..hear(['opción uno']);
    await press();
    expect(port.said[1], 'Este dispositivo solo puede mirar en ese host');
    expect(port.earcons, contains(Earcon.error));
    port.hear(['para api']);
    await press();
    expect(port.said.last, 'Este dispositivo solo puede mirar en ese host');
    expect(board.calls, isEmpty);
    expect(sessions.calls, isEmpty);
  });

  test('a failure is spoken as "No se pudo."', () async {
    await build();
    sessions.promptError = StateError('boom');
    port
      ..hear(['api'])
      ..hear(['dicta hola'])
      ..hear(['sí']);
    await press();
    expect(port.said, contains('No se pudo.'));
  });

  test('a new question is announced while armed; the press reads it', () async {
    await build();
    expect(port.said, isEmpty);
    board.set(_board(question: true));
    await settle();
    await voice.whenIdle();
    expect(port.said, ['codex de api pregunta. Pulsa para oír.']);
    await press();
    expect(port.said[1], 'codex de api te pregunta. ¿Migro en caliente?\nOpciones: 1, Migración en caliente. 2, Ventana de mantenimiento.');
    expect(voice.current, _apiKey);
  });

  test('an item that keeps coming back is announced twice at most', () async {
    await build();
    for (var i = 0; i < 4; i++) {
      board.set(_board(question: true));
      await settle();
      await voice.whenIdle();
      board.set(_board());
      await settle();
      await voice.whenIdle();
    }
    expect(port.said.where((t) => t == 'codex de api pregunta. Pulsa para oír.'), hasLength(2));
  });

  test('several open items at start are announced together', () async {
    hosts = FakeHostsRepository(hosts: const [HostStatus(_host, state: HostState.online)]);
    sessions = FakeSessionsRepository(sessions: [_api(), _web(menu: true)]);
    board = FakeBoardRepository(boards: {'estudio': _board(question: true)});
    hub = CarHub(hosts: hosts, sessions: sessions, board: board, debounce: Duration.zero, settleTimeout: const Duration(milliseconds: 200));
    port = FakeVoicePort();
    voice = VoiceController(port: port, hub: hub, timer: _timers(), noticeDelay: const Duration(milliseconds: 5));
    await voice.start();
    await settle();
    await voice.whenIdle();
    expect(port.said.first, 'Modo voz. Pulsa para hablar.');
    expect(port.said.last, anyOf('codex de api y claude de webapp esperan. Pulsa para oír.', 'claude de webapp y codex de api esperan. Pulsa para oír.'));
    // Next reads the first one, then a short listen.
    await press(VoiceButton.next);
    expect([_apiKey, _webKey], contains(voice.current));
    expect(port.listens, const [Duration(seconds: 6)]);
  });

  test('idle timeout says goodbye and exits', () async {
    await build();
    final idle = timers.lastWhere((t) => !t.cancelled);
    expect(idle.duration, const Duration(minutes: 20));
    idle.callback();
    await settle();
    await voice.whenIdle();
    expect(port.said.last, 'Salgo del modo voz.');
    expect(port.exits, 1);
    expect(voice.state, VoiceState.off);
    // Buttons do nothing once off.
    await press();
    expect(port.listens, isEmpty);
  });

  test('"salir" exits voice mode', () async {
    await build();
    port.hear(['adiós']);
    await press();
    expect(port.said.last, 'Salgo del modo voz.');
    expect(port.exits, 1);
    expect(voice.state, VoiceState.off);
  });
}
