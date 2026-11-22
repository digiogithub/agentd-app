// Panel tab: counters, what waits for the human, agent cards, the answer
// sheet (mailbox / prompt), terminal menus and one agent's task view.

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/app.dart';
import 'package:agentd_app/src/ui/fakes/sample_data.dart';
import 'package:agentd_app/src/ui/panel_model.dart';
import 'package:agentd_app/src/ui/screens/panel_agent_screen.dart';
import 'package:agentd_app/src/ui/screens/panel_screen.dart';
import 'package:agentd_app/src/ui/screens/session_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

const _panel = Scaffold(body: PanelScreen());

Finder _counter(String label, int value) =>
    find.descendant(of: find.byKey(ValueKey('panel-counter-$label')), matching: find.text('$value'));

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await settle(tester);
}

void main() {
  setUp(setUpUiTests);

  group('model', () {
    final now = DateTime(2026, 11, 22, 10);
    final sessions = sampleSessions(now);
    final boards = sampleBoards(now).values;

    test('waiting = questions, then terminal menus, then blocked tasks', () {
      final p = buildPanel(boards: boards, sessions: sessions);
      expect(p.waiting.map((w) => '${w.runtimeType}:${w.name}'), [
        'QuestionWaiting:pando@agentd',
        'MenuWaiting:codex@api', // 3 min, older than claude@webapp (1 min)
        'MenuWaiting:claude@webapp',
        'BlockedWaiting:codex@webapp',
      ]);
      expect((p.inProgress, p.pending), (4, 4));
      // Agents that wait first, then the working ones, idle without tasks last.
      expect(p.agents.map((a) => a.name), ['pando@agentd', 'claude@webapp', 'codex@api', 'codex@webapp', 'claude@docs']);
    });

    test('one host; hosts without a board list their agentd sessions', () {
      final one = buildPanel(boards: boards, sessions: sessions, hostId: 'vps-hetzner');
      expect(one.waiting.map((w) => w.name), ['codex@api', 'codex@webapp']);
      expect(one.agents.map((a) => a.name), ['codex@api', 'codex@webapp']);

      final none = buildPanel(boards: const [HostBoard(hostId: 'estudio', available: false)], sessions: sessions);
      expect(none.agents.map((a) => a.name), containsAll(['claude@webapp', 'pando@agentd', 'codex@api']));
      expect(none.agents.any((a) => a.name == 'main'), isFalse, reason: 'zellij sessions have no plan');
      expect(none.agents.every((a) => a.tasks.isEmpty), isTrue);
      expect(none.waiting.every((w) => w is MenuWaiting), isTrue);
    });

    test('question headline and progress', () {
      expect(splitQuestion('¿A o B?\n\nDetalle largo.\nMás.'), ('¿A o B?', 'Detalle largo.\nMás.'));
      expect(splitQuestion(' sola '), ('sola', ''));
      final s = sampleBoards(now)['vps-hetzner']!.sessions.last;
      expect(progressLabel(s), '1 / 2');
      expect(progressOf(s), 0.5);
      expect(progressOf(const BoardSession(hostId: 'h', name: 'x')), 0);
    });
  });

  testWidgets('counters, waiting cards and agent cards', (tester) async {
    await pumpUi(tester, _panel, height: 1500);
    expect(find.text('Panel'), findsOneWidget);
    expect(find.text('Todos los hosts'), findsOneWidget);
    expect(_counter('Te esperan', 4), findsOneWidget);
    expect(_counter('En curso', 4), findsOneWidget);
    expect(_counter('Pendientes', 4), findsOneWidget);

    // Two waiting items, the rest behind "N más".
    expect(find.text('¿Migro el esquema del buzón a v4 en este mismo cambio o lo separo en otro?'), findsOneWidget);
    expect(find.textContaining('Pregunta · 4 min'), findsOneWidget);
    expect(find.text('Responder'), findsNWidgets(2));
    expect(find.text('2 más'), findsOneWidget);
    expect(find.text('Sí'), findsNothing);

    await _tap(tester, find.text('2 más'));
    expect(find.text('Sí'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    expect(find.textContaining('Bloqueada'), findsOneWidget);
    expect(find.text('Falta la credencial del registro de contenedores'), findsOneWidget);

    // Agents: progress and current task; without tasks, status and preview.
    expect(find.text('3 / 7'), findsOneWidget);
    expect(find.text('Op board: resumen agregado por sesión'), findsOneWidget);
    expect(find.text('5 / 6'), findsOneWidget);
    expect(find.text('README actualizado con la sección de instalación'), findsOneWidget);
    expect(find.text('Listo'), findsOneWidget);
  });

  testWidgets('an option answers the question through the mailbox', (tester) async {
    final f = await pumpUi(tester, _panel, height: 1500);
    await _tap(tester, find.text('Responder').first);
    expect(find.text('Bloquea la tarea «Persistir tareas en SQLite»'), findsOneWidget);
    expect(find.textContaining('Si va junto, el cambio toca también la purga'), findsOneWidget);
    expect(find.text('estudio · trabajando · hace 4 min'), findsOneWidget);

    // No text: nothing to send.
    await _tap(tester, find.byKey(const ValueKey('answer-send')));
    expect(f.board.calls, isEmpty);

    // Options ignore the Buzón / Prompt toggle: always a reply.
    await _tap(tester, find.byKey(const ValueKey('target-prompt')));
    await _tap(tester, find.text('Cambio aparte'));
    final call = f.board.calls.single;
    expect((call.method, call.session, call.arg, call.notify), ('answer', '310', 'Cambio aparte', true));
    expect(f.sessions.calls, isEmpty);
    // The sheet closed and the question left the Panel.
    expect(find.byKey(const ValueKey('answer-send')), findsNothing);
    expect(find.text('¿Migro el esquema del buzón a v4 en este mismo cambio o lo separo en otro?'), findsNothing);
    expect(_counter('Te esperan', 3), findsOneWidget);
  });

  testWidgets('free text to the mailbox is a reply', (tester) async {
    final f = await pumpUi(tester, _panel, height: 1500);
    await _tap(tester, find.text('Responder').first);
    await tester.enterText(find.byKey(const ValueKey('answer-text')), '  Sepáralo, pero hoy  ');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('answer-send')));
    expect((f.board.calls.single.arg, f.board.calls.single.notify), ('Sepáralo, pero hoy', true));
    expect(f.sessions.calls, isEmpty);
  });

  testWidgets('free text to the prompt types it, then closes the question with a quiet reply', (tester) async {
    final f = await pumpUi(tester, _panel, height: 1500);
    await _tap(tester, find.text('Responder').first);
    await tester.enterText(find.byKey(const ValueKey('answer-text')), 'Sepáralo');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('target-prompt')));
    await _tap(tester, find.byKey(const ValueKey('answer-send')));
    final call = f.sessions.calls.single;
    expect((call.method, call.session, call.arg), ('prompt', 'pando@agentd', 'Sepáralo'));
    final reply = f.board.calls.single;
    expect((reply.session, reply.arg, reply.notify), ('310', 'Sepáralo', false), reason: 'recorded, not injected again');
    expect(find.byKey(const ValueKey('answer-send')), findsNothing);
    expect(_counter('Te esperan', 3), findsOneWidget);
  });

  testWidgets('a prompt that worked is kept when the quiet reply fails', (tester) async {
    final f = await pumpUi(tester, _panel, height: 1500);
    f.board.answerError = StateError('old daemon');
    await _tap(tester, find.text('Responder').first);
    await tester.enterText(find.byKey(const ValueKey('answer-text')), 'Sepáralo');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('target-prompt')));
    await _tap(tester, find.byKey(const ValueKey('answer-send')));
    expect(f.sessions.calls.single.method, 'prompt');
    expect(find.text('Escrito en el prompt, pero la pregunta sigue abierta en el buzón'), findsOneWidget);
    expect(find.byKey(const ValueKey('answer-send')), findsNothing, reason: 'the sheet closed');
  });

  testWidgets('a failed prompt sends no reply and keeps the sheet open', (tester) async {
    final f = await pumpUi(tester, _panel, height: 1500);
    f.sessions.promptError = StateError('busy');
    f.board.answerError = StateError('offline');
    await _tap(tester, find.text('Responder').first);
    await tester.enterText(find.byKey(const ValueKey('answer-text')), 'Sepáralo');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('target-prompt')));
    await _tap(tester, find.byKey(const ValueKey('answer-send')));
    expect(find.text('No se pudo escribir en el prompt'), findsOneWidget);
    expect(f.board.calls, isEmpty);
    expect(find.byKey(const ValueKey('answer-send')), findsOneWidget);
  });

  testWidgets('a failed answer keeps the sheet open', (tester) async {
    final f = await pumpUi(tester, _panel, height: 1500);
    f.board.answerError = StateError('offline');
    await _tap(tester, find.text('Responder').first);
    await _tap(tester, find.text('Cambio aparte'));
    expect(find.text('No se pudo enviar la respuesta'), findsOneWidget);
    expect(find.byKey(const ValueKey('answer-send')), findsOneWidget);
  });

  testWidgets('terminal menus: Sí / No choose with revision and epoch; other menus in a sheet', (tester) async {
    final f = await pumpUi(tester, _panel, height: 1500);
    await _tap(tester, find.text('2 más'));
    expect(find.textContaining('go test ./internal/... -race'), findsOneWidget);
    await _tap(tester, find.text('No'));
    var call = f.sessions.calls.single;
    expect((call.method, call.session, call.arg, call.revision, call.epoch), ('choose', 'claude@webapp', 'o-no', 41, kEpoch));

    // codex@api asks with three options: the second "Responder".
    await _tap(tester, find.text('Responder').last);
    expect(find.text('Dejarlo para el despliegue y documentarlo'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('menu-option-q-now')));
    call = f.sessions.calls.last;
    expect((call.session, call.arg, call.revision, call.epoch), ('codex@api', 'q-now', 17, kEpoch));
    expect(find.byKey(const ValueKey('menu-option-q-now')), findsNothing);
  });

  testWidgets('host filter narrows the Panel', (tester) async {
    await pumpUi(tester, _panel, height: 1500);
    await _tap(tester, find.byKey(const ValueKey('panel-host')));
    await _tap(tester, find.text('vps-hetzner').last);
    expect(_counter('Te esperan', 2), findsOneWidget);
    expect(find.text('pando@agentd'), findsNothing);
    expect(find.text('codex@api'), findsWidgets);
    expect(find.text('Todos los hosts'), findsNothing);
  });

  testWidgets('a view-only relay device reads but can not answer', (tester) async {
    final f = Fakes();
    await f.hosts.save(
      const HostConfig(
        id: 'estudio',
        name: 'estudio',
        host: 'relay.example',
        port: 0,
        user: '',
        transport: HostTransport.relay,
        relay: RelayHostInfo(relayUrl: 'https://relay.example', route: 'r', hostKey: 'k', deviceId: 'd', scope: RelayScope.view, kind: 'owner'),
      ),
    );
    await pumpUi(tester, _panel, fakes: f, height: 1500);
    await _tap(tester, find.text('2 más'));
    // estudio: the question and the permission are shown, not answerable.
    expect(find.text('Sí'), findsNothing);
    expect(find.text('Ver'), findsNWidgets(2));
    await _tap(tester, find.text('Ver').first);
    expect(find.text('Este dispositivo solo puede mirar: no puede responder.'), findsOneWidget);
    expect(find.byKey(const ValueKey('answer-send')), findsNothing);
    expect(find.text('Cambio aparte'), findsNothing);
  });

  testWidgets('agent view: tasks by state, open question and a message to the mailbox', (tester) async {
    final f = await pumpUi(tester, const PanelAgentScreen(hostId: 'estudio', name: 'pando@agentd'), height: 1500);
    expect(find.text('pando@agentd'), findsOneWidget);
    expect(find.text('estudio · ~/src/agentd'), findsOneWidget);
    expect(find.text('Trabajando'), findsOneWidget);
    expect(find.text('3 / 7 · hace 1 min'), findsOneWidget);
    expect(find.text('TE PREGUNTA'), findsOneWidget);
    expect(find.text('EN CURSO · 2'), findsOneWidget);
    expect(find.text('PENDIENTES · 2'), findsOneWidget);
    expect(find.text('HECHAS · 3'), findsOneWidget);
    expect(find.text('BLOQUEADAS · 1'), findsNothing);
    expect(find.text('Pregunta abierta: ¿Migro el esquema del buzón a v4 en este mismo cambio o lo separo en otro?'), findsOneWidget);

    // Send is off until there is text.
    await _tap(tester, find.byKey(const ValueKey('agent-send')));
    expect(f.mail.sent, isEmpty);
    await tester.enterText(find.byKey(const ValueKey('agent-message')), 'Prioriza la purga');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('agent-send')));
    final sent = f.mail.sent.single;
    expect((sent.session, sent.arg), ('pando@agentd', 'Prioriza la purga'));
    expect(f.sessions.calls, isEmpty);
    expect(find.text('Mensaje enviado al buzón'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('agent-message')), 'sigue');
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey('target-prompt')));
    await _tap(tester, find.byKey(const ValueKey('agent-send')));
    expect((f.sessions.calls.single.method, f.sessions.calls.single.arg), ('prompt', 'sigue'));
    expect(find.text('Escrito en el prompt'), findsOneWidget);
  });

  testWidgets('agent view: blocked and cancelled tasks; the question opens the answer sheet', (tester) async {
    await pumpUi(tester, const PanelAgentScreen(hostId: 'vps-hetzner', name: 'codex@webapp'), height: 1500);
    expect(find.text('BLOQUEADAS · 1'), findsOneWidget);
    expect(find.text('Falta la credencial del registro de contenedores'), findsOneWidget);
    expect(find.text('CANCELADAS · 1'), findsOneWidget);
    expect(find.text('1 / 2 · hace 40 min'), findsOneWidget);

    final f = await pumpUi(tester, const PanelAgentScreen(hostId: 'estudio', name: 'pando@agentd'), height: 1500);
    await _tap(tester, find.byKey(const ValueKey('agent-question-310')));
    await _tap(tester, find.text('En este cambio'));
    expect(f.board.calls.single.arg, 'En este cambio');
    expect(find.text('TE PREGUNTA'), findsNothing);
  });

  testWidgets('agent without tasks, and a session that is gone', (tester) async {
    await pumpUi(tester, const PanelAgentScreen(hostId: 'estudio', name: 'claude@docs'));
    expect(find.textContaining('Este agente no ha informado de tareas.'), findsOneWidget);
    expect(find.textContaining('README actualizado'), findsOneWidget);

    await pumpUi(tester, const PanelAgentScreen(hostId: 'estudio', name: 'nadie@nada'));
    expect(find.text('Esta sesión ya no está en el panel.'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-send')), findsNothing);
  });

  testWidgets('Panel is the first tab; cards open the agent and its chat', (tester) async {
    await pumpUi(tester, const AppShell(), height: 1500);
    expect(find.text('Te esperan'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('panel-agent-estudio/agentd/pando@agentd')));
    expect(find.byType(PanelAgentScreen), findsOneWidget);
    await _tap(tester, find.bySemanticsLabel('Abrir chat'));
    expect(find.byType(SessionScreen), findsOneWidget);
  });
}
