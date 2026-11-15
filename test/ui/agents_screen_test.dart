import 'package:agentd_app/src/ui/app.dart';
import 'package:agentd_app/src/ui/fakes/sample_data.dart';
import 'package:agentd_app/src/ui/screens/agents_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

void main() {
  setUp(setUpUiTests);

  testWidgets('groups sessions as in the mockup', (tester) async {
    await pumpUi(tester, const Scaffold(body: AgentsScreen()));
    expect(find.text('Agentes'), findsOneWidget);
    expect(find.text('3 hosts · 7 sesiones'), findsOneWidget);
    expect(find.text('NECESITAN RESPUESTA · 2'), findsOneWidget);
    expect(find.text('TRABAJANDO · 2'), findsOneWidget);
    expect(find.text('LISTOS · 3'), findsOneWidget);
    expect(find.text('claude@webapp'), findsOneWidget);
    expect(find.text('Permiso'), findsOneWidget);
    expect(find.text('Pregunta'), findsOneWidget);
    expect(find.text('3 opciones · toca para responder'), findsOneWidget);
    expect(find.text('zellij · main'), findsOneWidget);
    expect(find.text('Nueva sesión'), findsOneWidget);
  });

  testWidgets('Permitir calls choose with the revision and epoch', (tester) async {
    final f = await pumpUi(tester, const Scaffold(body: AgentsScreen()));
    await tester.tap(find.text('Permitir'));
    await settle(tester);
    final call = f.sessions.calls.singleWhere((c) => c.method == 'choose');
    expect(call.session, 'claude@webapp');
    expect(call.arg, 'o-yes');
    expect(call.revision, 41);
    expect(call.epoch, kEpoch);
    // The session left the waiting group.
    expect(find.text('NECESITAN RESPUESTA · 1'), findsOneWidget);
  });

  testWidgets('Denegar picks the deny option', (tester) async {
    final f = await pumpUi(tester, const Scaffold(body: AgentsScreen()));
    await tester.tap(find.text('Denegar'));
    await settle(tester);
    expect(f.sessions.calls.single.arg, 'o-no');
  });

  testWidgets('filter chips narrow the list', (tester) async {
    await pumpUi(tester, const Scaffold(body: AgentsScreen()));
    await tester.ensureVisible(find.text('Trabajando · 2'));
    await tester.tap(find.text('Trabajando · 2'));
    await tester.pump();
    expect(find.text('claude@webapp'), findsNothing);
    expect(find.text('pando@agentd'), findsOneWidget);
    expect(find.text('NECESITAN RESPUESTA · 2'), findsNothing);

    await tester.ensureVisible(find.text('Listos · 3'));
    await tester.tap(find.text('Listos · 3'));
    await tester.pump();
    expect(find.text('claude@docs'), findsOneWidget);
    expect(find.text('pando@agentd'), findsNothing);
  });

  testWidgets('bottom nav switches tabs', (tester) async {
    await pumpUi(tester, const AppShell());
    expect(find.text('Agentes'), findsWidgets);
    await tester.tap(find.bySemanticsLabel('Hosts'));
    await settle(tester);
    expect(find.text('estudio'), findsWidgets);
    expect(find.text('Instalar agentd en portatil'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Buzón'));
    await settle(tester);
    expect(find.text('Mensajes · 4'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Ajustes'));
    await settle(tester);
    expect(find.text('AVISARME CUANDO'), findsOneWidget);
  });

  testWidgets('tapping a card opens the session', (tester) async {
    await pumpUi(tester, const Scaffold(body: AgentsScreen()));
    await tester.tap(find.text('codex@api'));
    await settle(tester);
    expect(find.text('¿Migro la tabla sessions ahora o dejo la migración para el despliegue?'), findsWidgets);
    expect(find.text('Responder'), findsOneWidget);
  });
}
