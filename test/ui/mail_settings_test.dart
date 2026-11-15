import 'package:agentd_app/src/ui/screens/mailbox_screen.dart';
import 'package:agentd_app/src/ui/screens/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

void main() {
  setUp(setUpUiTests);

  group('mailbox', () {
    testWidgets('shows messages, replies and queues', (tester) async {
      await pumpUi(tester, const Scaffold(body: MailboxScreen()));
      expect(find.text('Buzón'), findsOneWidget);
      expect(find.text('Mensajes entre agentes · estudio'), findsOneWidget);
      expect(find.text('Mensajes · 4'), findsOneWidget);
      expect(find.text('Colas · 2'), findsOneWidget);
      expect(find.text('#144 · se entregará cuando claude@agentd quede libre'), findsOneWidget);
      expect(find.text('Sí, endpoint /v1/session con expires_at. Tests en verde.'), findsOneWidget);
      expect(find.text('Respondido'), findsOneWidget);
      expect(find.text('tú'), findsWidgets);

      await tester.tap(find.text('Colas · 2'));
      await tester.pump();
      expect(find.text('queue:review'), findsOneWidget);
      expect(find.text('3 sin reclamar'), findsOneWidget);
      expect(find.text('#151 · Revisar PR de expiración de tokens · de codex@api'), findsOneWidget);
      expect(find.text('0 sin reclamar'), findsOneWidget);
      expect(find.textContaining('#148 reclamado por claude@webapp'), findsOneWidget);
    });

    testWidgets('sends to a queue', (tester) async {
      final f = await pumpUi(tester, const Scaffold(body: MailboxScreen()));
      await tester.tap(find.text('Enviar a agente o cola'));
      await settle(tester);
      await tester.tap(find.text('queue:review'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'Revisa la PR 12');
      await tester.tap(find.text('Enviar'));
      await settle(tester);
      expect(f.mail.sent.single.session, 'queue:review');
      expect(f.mail.sent.single.arg, 'Revisa la PR 12');
      await tester.tap(find.textContaining('Colas ·'));
      await tester.pump();
      expect(find.text('4 sin reclamar'), findsOneWidget);
    });
  });

  group('settings', () {
    testWidgets('toggles switches and unmutes', (tester) async {
      await pumpUi(tester, const Scaffold(body: SettingsScreen()), height: 1100);
      expect(find.text('Ajustes'), findsOneWidget);
      expect(find.text('Un agente espera respuesta'), findsOneWidget);
      expect(find.text('Activado'), findsOneWidget);

      final exit = find.bySemanticsLabel('Una sesión se cierra');
      expect(tester.getSemantics(exit), isSemantics(isToggled: false));
      await tester.tap(exit);
      await tester.pump();
      expect(tester.getSemantics(exit), isSemantics(isToggled: true));

      expect(find.text('claude@docs'), findsOneWidget);
      await tester.tap(find.text('Quitar'));
      await tester.pump();
      expect(find.text('claude@docs'), findsNothing);
      expect(find.text('Ninguna sesión silenciada'), findsOneWidget);

      await tester.tap(find.text('Sistema'));
      await tester.pump();
      expect(find.textContaining('El tema claro llegará pronto'), findsOneWidget);
    });
  });
}
