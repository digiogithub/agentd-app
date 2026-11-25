
import 'package:agentd_app/src/car/car_hub.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/fakes/fake_repositories.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = HostConfig(id: 'h1', name: 'estudio', host: 'estudio.local', user: 'jose');
const _key = 'h1/agentd/codex@api';
const _menuKey = 'h1/agentd/claude@webapp';

AgentSession _menuSession() => AgentSession(
      hostId: 'h1',
      source: SessionSource.agentd,
      name: 'claude@webapp',
      status: AgentStatus.waiting,
      pending: const PendingInteraction(
        question: 'Do you want to run npm run lint?',
        kind: PendingKind.permission,
        detail: 'npm run lint',
        revision: 7,
        epoch: 'e1',
        options: [SessionOption(id: 'o1', label: 'Yes', index: 1), SessionOption(id: 'o2', label: 'No', index: 2)],
      ),
      updatedAt: DateTime(2026, 11, 25, 10),
    );

HostBoard _board({bool question = true}) => HostBoard(hostId: 'h1', sessions: [
      BoardSession(
        hostId: 'h1',
        name: 'codex@api',
        status: AgentStatus.waiting,
        tasks: const [AgentTask(id: 't1', title: 'Migrar la base de datos', status: TaskStatus.blocked, note: 'falta la ventana')],
        questions: [
          if (question) AgentQuestion(id: 41, body: '¿Migro en caliente?\n\nDetalles largos.', options: const ['Migración en caliente', 'Ventana de mantenimiento'], createdAt: DateTime(2026, 11, 25, 9)),
        ],
      ),
      const BoardSession(hostId: 'h1', name: 'claude@webapp', status: AgentStatus.waiting),
    ]);

void main() {
  late FakeHostsRepository hosts;
  late FakeSessionsRepository sessions;
  late FakeBoardRepository board;
  late CarHub hub;

  setUp(() {
    hosts = FakeHostsRepository(hosts: const [HostStatus(_host, state: HostState.online)]);
    sessions = FakeSessionsRepository(sessions: [
      AgentSession(hostId: 'h1', source: SessionSource.agentd, name: 'codex@api', status: AgentStatus.waiting, updatedAt: DateTime(2026, 11, 25, 9)),
      _menuSession(),
    ]);
    board = FakeBoardRepository(boards: {'h1': _board()});
    hub = CarHub(hosts: hosts, sessions: sessions, board: board, debounce: Duration.zero, viewTimeout: const Duration(milliseconds: 200), settleTimeout: const Duration(milliseconds: 200));
  });

  tearDown(() => hub.dispose());

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('snapshot carries questions, menus and blocked tasks; notices once', () async {
    final notices = <CarNotice>[];
    hub.notices.listen(notices.add);
    hub.start();
    await settle();
    final agents = (hub.snapshot['agents']! as List).cast<Map<String, Object?>>();
    expect(hub.snapshot['online'], 1);
    final codex = agents.firstWhere((a) => a['key'] == _key);
    expect(codex['host'], 'estudio');
    expect((codex['questions']! as List).single, containsPair('headline', '¿Migro en caliente?'));
    expect((codex['blocked']! as List).single, {'title': 'Migrar la base de datos', 'note': 'falta la ventana'});
    final claude = agents.firstWhere((a) => a['key'] == _menuKey);
    expect((claude['menu']! as Map)['options'], [
      {'id': 'o1', 'label': 'Yes'},
      {'id': 'o2', 'label': 'No'},
    ]);
    expect(notices.map((n) => n.tag), unorderedEquals(['q/h1/41', 'm/$_menuKey/7']));
    final q = notices.firstWhere((n) => n.tag == 'q/h1/41');
    expect(q.title, 'codex@api te pregunta');
    expect(q.text, contains('Opciones: 1, Migración en caliente. 2, Ventana de mantenimiento.'));
    expect(notices.firstWhere((n) => n.tag.startsWith('m/')).title, 'claude@webapp pide permiso');

    hub.rebuild();
    expect(notices, hasLength(2));
  });

  test('a closed question cancels its notice', () async {
    final cancels = <String>[];
    hub.cancels.listen(cancels.add);
    hub.start();
    await settle();
    board.set(_board(question: false));
    await settle();
    expect(cancels, ['q/h1/41']);
  });

  test('voice reply answers the question with the option it names', () async {
    hub.start();
    await settle();
    expect(await hub.reply(_key, 'la segunda'), 'Respondido a codex@api: Ventana de mantenimiento');
    expect(board.calls.single.session, '41');
    expect(board.calls.single.arg, 'Ventana de mantenimiento');
  });

  test('voice reply with free words answers with the words', () async {
    hub.start();
    await settle();
    expect(await hub.reply(_key, 'Espera a mañana'), 'Respuesta enviada a codex@api');
    expect(board.calls.single.arg, 'Espera a mañana');
  });

  test('voice reply picks the menu option, or says the options', () async {
    hub.start();
    await settle();
    await expectLater(hub.reply(_menuKey, 'quizá'), throwsA(isA<CarActionException>().having((e) => e.message, 'message', contains('1, Yes. 2, No.'))));
    expect(await hub.reply(_menuKey, 'sí'), 'Elegido en claude@webapp: Yes');
    final c = sessions.calls.singleWhere((c) => c.method == 'choose');
    expect((c.arg, c.revision, c.epoch), ('o1', 7, 'e1'));
  });

  test('voice reply without anything open is an instruction', () async {
    board.set(_board(question: false));
    hub.start();
    await settle();
    expect(await hub.reply(_key, 'Usa la ventana del sábado'), 'Instrucción enviada a codex@api');
    expect(sessions.calls.single.method, 'prompt');
    expect(sessions.calls.single.arg, 'Usa la ventana del sábado');
  });

  test('view-only relay devices cannot act and get no notices', () async {
    hosts = FakeHostsRepository(hosts: const [
      HostStatus(
        HostConfig(id: 'h1', name: 'estudio', host: '', user: '', transport: HostTransport.relay, relay: RelayHostInfo(relayUrl: 'wss://r', route: 'r', hostKey: 'k', deviceId: 'd', scope: RelayScope.view)),
        state: HostState.online,
      ),
    ]);
    hub = CarHub(hosts: hosts, sessions: sessions, board: board, debounce: Duration.zero, settleTimeout: const Duration(milliseconds: 200));
    final notices = <CarNotice>[];
    hub.notices.listen(notices.add);
    hub.start();
    await settle();
    expect(notices, isEmpty);
    await expectLater(hub.reply(_key, 'sí'), throwsA(isA<CarActionException>()));
    expect(board.calls, isEmpty);
  });

  test('conclusion is the last agent message, read aloud', () async {
    hub.start();
    await settle();
    final c = await hub.conclusion(_key);
    expect(c, isNotEmpty);
    expect(c, isNot(contains('`')));
    expect(await hub.lastLines(_key, 2), hasLength(lessThanOrEqualTo(2)));
  });

  test('a reply right after a cold start waits for the board', () async {
    hub = CarHub(hosts: hosts, sessions: sessions, board: _SlowBoard(board), debounce: Duration.zero, settleTimeout: const Duration(seconds: 2));
    hub.start();
    // The board arrives 100 ms later: the reply must still answer the question.
    expect(await hub.reply(_key, 'uno'), 'Respondido a codex@api: Migración en caliente');
    expect(sessions.calls.where((c) => c.method == 'prompt'), isEmpty);
  });

  test('offline hosts drop out of the snapshot', () async {
    hosts = FakeHostsRepository(hosts: const [HostStatus(_host)]);
    hub = CarHub(hosts: hosts, sessions: sessions, board: board, debounce: Duration.zero, settleTimeout: const Duration(milliseconds: 200));
    final snaps = <Map<String, Object?>>[];
    hub.snapshots.listen(snaps.add);
    hub.start();
    await settle();
    expect(snaps.last['agents'], isEmpty);
    expect(snaps.last['online'], 0);
  });
}

class _SlowBoard implements BoardRepository {
  _SlowBoard(this.inner);
  final FakeBoardRepository inner;

  @override
  Stream<HostBoard> watch(String hostId) async* {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    yield* inner.watch(hostId);
  }

  @override
  Future<void> answer(String hostId, int questionId, String body, {bool notify = true}) => inner.answer(hostId, questionId, body, notify: notify);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
