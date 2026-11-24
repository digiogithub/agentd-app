// Backlog section of the Panel: list, add, edit, delete, reopen and assign a
// note to a running agent of the same host.

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/fakes/sample_data.dart';
import 'package:agentd_app/src/ui/screens/panel_backlog.dart';
import 'package:agentd_app/src/ui/screens/panel_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

const _panel = Scaffold(body: PanelScreen());

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await settle(tester);
}

void main() {
  setUp(setUpUiTests);

  testWidgets('lists open and assigned notes of the hosts that have a backlog; done ones on demand', (tester) async {
    await pumpUi(tester, _panel, height: 2600);
    await settle(tester);
    // estudio has a backlog; vps-hetzner (an older agentd) has no section.
    expect(find.byKey(const ValueKey('backlog-estudio')), findsOneWidget);
    expect(find.byKey(const ValueKey('backlog-vps-hetzner')), findsNothing);
    expect(find.text('BACKLOG · ESTUDIO'), findsOneWidget);
    expect(find.text('Probar el emparejado por QR en iOS'), findsOneWidget);
    expect(find.text('Revisar los tiempos de reconexión del relay'), findsOneWidget);
    expect(find.text('Asignada a claude@docs'), findsOneWidget);
    expect(find.text('Borrar las ramas viejas'), findsNothing);
    await _tap(tester, find.text('1 nota hecha'));
    expect(find.text('Borrar las ramas viejas'), findsOneWidget);
    expect(find.text('Hecha por pando@agentd'), findsOneWidget);
  });

  testWidgets('add a note: title needed, body optional', (tester) async {
    final f = await pumpUi(tester, _panel, height: 2600);
    await settle(tester);
    await _tap(tester, find.byKey(const ValueKey('backlog-add-estudio')));
    expect(find.text('Nueva nota'), findsOneWidget);
    await tester.tap(find.text('Añadir al backlog'));
    await tester.pump();
    expect(find.text('Escribe un título'), findsOneWidget);
    expect(f.board.calls, isEmpty);
    await tester.enterText(find.byKey(const ValueKey('note-title')), '  Medir el arranque en frío ');
    await tester.enterText(find.byKey(const ValueKey('note-body')), 'En un Pixel 6\ny en un iPhone 13');
    await tester.tap(find.text('Añadir al backlog'));
    await settle(tester);
    expect(f.board.calls.single.method, 'addNote');
    expect(f.board.calls.single.arg, ('Medir el arranque en frío', 'En un Pixel 6\ny en un iPhone 13'));
    expect(find.text('Nueva nota'), findsNothing);
    expect(find.text('Medir el arranque en frío'), findsOneWidget);
  });

  testWidgets('edit sends only what changed; a refusal keeps the sheet', (tester) async {
    final f = await pumpUi(tester, _panel, height: 2600);
    await settle(tester);
    await _tap(tester, find.text('Revisar los tiempos de reconexión del relay'));
    expect(find.text('Nota del backlog'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('note-body')), 'Con el túnel caído 1 min');
    f.board.noteError = const BacklogException(BacklogFailure.invalid);
    await tester.tap(find.text('Guardar'));
    await settle(tester);
    expect(find.textContaining('El host no aceptó la nota'), findsOneWidget);
    expect(find.text('Nota del backlog'), findsOneWidget);
    f.board.noteError = null;
    await tester.tap(find.text('Guardar'));
    await settle(tester);
    expect(f.board.calls.last.method, 'updateNote');
    expect((f.board.calls.last.session, f.board.calls.last.arg), ('3', (null, 'Con el túnel caído 1 min', false)));
    expect(find.text('Nota del backlog'), findsNothing);
    expect(find.text('Con el túnel caído 1 min'), findsOneWidget);
  });

  testWidgets('delete asks first', (tester) async {
    final f = await pumpUi(tester, _panel, height: 2600);
    await settle(tester);
    await _tap(tester, find.text('Revisar los tiempos de reconexión del relay'));
    await _tap(tester, find.text('Eliminar'));
    expect(find.text('¿Eliminar la nota?'), findsOneWidget);
    await _tap(tester, find.text('Cancelar'));
    expect(f.board.calls, isEmpty);
    await _tap(tester, find.text('Eliminar'));
    await _tap(tester, find.widgetWithText(TextButton, 'Eliminar'));
    expect((f.board.calls.single.method, f.board.calls.single.session), ('removeNote', '3'));
    expect(find.text('Revisar los tiempos de reconexión del relay'), findsNothing);
  });

  testWidgets('assign: a running agent of the same host, pending or in progress', (tester) async {
    final f = await pumpUi(tester, _panel, height: 2600);
    await settle(tester);
    await _tap(tester, find.byKey(const ValueKey('backlog-assign-estudio-4')));
    expect(find.text('Asignar a un agente'), findsOneWidget);
    // Only the sessions of estudio.
    for (final s in sampleBoards(DateTime.now())['estudio']!.sessions) {
      expect(find.byKey(ValueKey('assign-session-${s.name}')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('assign-session-codex@api')), findsNothing);
    // Nothing is sent without an agent.
    await tester.tap(find.text('Asignar').last, warnIfMissed: false);
    await settle(tester);
    expect(f.board.calls, isEmpty);
    await _tap(tester, find.byKey(const ValueKey('assign-session-claude@docs')));
    await _tap(tester, find.text('En curso').last);
    await _tap(tester, find.text('Asignar').last);
    expect((f.board.calls.single.method, f.board.calls.single.session, f.board.calls.single.arg), ('assignNote', '4', ('claude@docs', true)));
    expect(find.text('Asignada a claude@docs'), findsNWidgets(3), reason: 'two cards and the toast');
    // The note is now a task of the agent, marked as coming from the backlog.
    final board = (await tester.runAsync(() => f.board.watch('estudio').first))!;
    final task = board.sessions.firstWhere((s) => s.name == 'claude@docs').tasks.single;
    expect((task.id, task.status, task.fromBacklog), ('n4', TaskStatus.inProgress, true));
  });

  testWidgets('assign refusals and the notice warning are said', (tester) async {
    final f = await pumpUi(tester, _panel, height: 2600);
    await settle(tester);
    await _tap(tester, find.byKey(const ValueKey('backlog-assign-estudio-4')));
    await _tap(tester, find.byKey(const ValueKey('assign-session-claude@docs')));
    f.board.noteError = const BacklogException(BacklogFailure.sessionNotRunning);
    await _tap(tester, find.text('Asignar').last);
    expect(find.text('El agente no está en marcha'), findsOneWidget);
    expect(find.text('Asignar a un agente'), findsOneWidget);
    f.board
      ..noteError = null
      ..assignWarning = 'mailbox: store closed';
    await _tap(tester, find.text('Asignar').last);
    await settle(tester, frames: 20); // the first toast leaves, the second one enters
    expect(find.textContaining('no se le pudo avisar por el buzón'), findsOneWidget);
    expect(find.text('Asignar a un agente'), findsNothing);
  });

  testWidgets('an assigned note can go to another agent or back to the backlog', (tester) async {
    final f = await pumpUi(tester, _panel, height: 2600);
    await settle(tester);
    await _tap(tester, find.text('Documentar el formato de las notas'));
    expect(find.text('Asignar a otro agente'), findsOneWidget);
    await _tap(tester, find.text('Devolver al backlog'));
    expect((f.board.calls.single.method, f.board.calls.single.arg), ('updateNote', (null, null, true)));
    expect(find.byKey(const ValueKey('backlog-assign-estudio-2')), findsOneWidget);
  });

  testWidgets('a relay device without the right sees no backlog', (tester) async {
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
    await pumpUi(tester, _panel, fakes: f, height: 2600);
    await settle(tester);
    expect(find.byKey(const ValueKey('backlog-estudio')), findsNothing);
    expect(find.textContaining('BACKLOG'), findsNothing);
  });

  testWidgets('a host without agents still offers its backlog; no agents to assign to', (tester) async {
    final f = Fakes();
    f.board.set(const HostBoard(hostId: 'estudio', backlog: true, notes: [BacklogNote(id: 1, title: 'Idea suelta')]));
    f.board.set(const HostBoard(hostId: 'vps-hetzner'));
    await pumpUi(tester, _panel, fakes: f, height: 1500);
    await settle(tester);
    expect(find.byKey(const ValueKey('backlog-estudio')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('backlog-assign-estudio-1')));
    expect(find.textContaining('No hay agentes en marcha en este host'), findsOneWidget);
  });

  test('error texts', () {
    for (final v in BacklogFailure.values) {
      expect(backlogErrorText(BacklogException(v)), isNotEmpty);
      expect(backlogErrorText(BacklogException(v), assigning: true), isNotEmpty);
    }
    expect(backlogErrorText(StateError('x')), contains('sin conexión'));
  });
}
