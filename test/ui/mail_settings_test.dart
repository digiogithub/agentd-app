import 'package:agentd_app/src/ui/providers.dart';
import 'package:agentd_app/src/ui/screens/mailbox_screen.dart';
import 'package:agentd_app/src/ui/screens/settings_screen.dart';
import 'package:agentd_app/src/ui/widgets/dictation/dictation_providers.dart';
import 'package:agentd_app/src/ui/widgets/dictation/dictation_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

      await tester.scrollUntilVisible(find.text('Sistema'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Sistema'));
      await tester.pump();
      expect(find.textContaining('llegará pronto'), findsNothing);
    });

    testWidgets('chat text size and font', (tester) async {
      await pumpUi(tester, const Scaffold(body: SettingsScreen()), height: 1100);
      await tester.scrollUntilVisible(find.text('Tipo de letra'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('14.5 pt'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Texto más grande'));
      await tester.pump();
      expect(find.text('15.5 pt'), findsOneWidget);
      await tester.tap(find.text('Serif'));
      await tester.pump();
      final c = ProviderScope.containerOf(tester.element(find.byType(SettingsScreen)));
      expect((c.read(settingsProvider).chatFontSize, c.read(settingsProvider).chatFont), (15.5, ChatFont.serif));

      await tester.tap(find.byKey(const ValueKey('chat-font-reading')));
      await tester.pump();
      expect(c.read(settingsProvider).chatFont, ChatFont.reading);
      await tester.scrollUntilVisible(find.text('Amplio'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Amplio'));
      await tester.pump();
      expect(c.read(settingsProvider).chatLineHeight, ChatLineHeight.wide);
    });

    testWidgets('picks and persists the dictation language', (tester) async {
      final store = _MemStore();
      final f = Fakes();
      await pumpUi(
        tester,
        const Scaffold(body: SettingsScreen()),
        fakes: f,
        height: 1300,
        extraOverrides: [
          dictationServiceProvider.overrideWithValue(_FakeSpeech()),
          dictationLocaleStoreProvider.overrideWithValue(store),
        ],
      );
      expect(find.text('Automático'), findsOneWidget);
      await tester.tap(find.text('Idioma del dictado'));
      await settle(tester);
      await tester.tap(find.text('English'));
      await settle(tester);
      expect(store.value, 'en_US');
      expect(find.text('en_US'), findsOneWidget);
    });
  });
}

class _MemStore implements DictationLocaleStore {
  String? value;
  @override
  Future<String?> load() async => value;
  @override
  Future<void> save(String? id) async => value = id;
}

class _FakeSpeech implements DictationService {
  @override
  Stream<DictationStatus> get status => const Stream.empty();
  @override
  Stream<DictationError> get errors => const Stream.empty();
  @override
  Future<DictationAvailability> initialize() async =>
      DictationAvailability.available;
  @override
  Future<void> listen({
    String? localeId,
    required void Function(String, bool) onResult,
    void Function(double)? onSoundLevel,
  }) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<List<DictationLocale>> locales() async => const [
    DictationLocale('es_ES', 'Español'),
    DictationLocale('en_US', 'English'),
  ];
  @override
  Future<String?> systemLocaleId() async => null;
}
