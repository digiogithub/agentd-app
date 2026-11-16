import 'package:agentd_app/src/agentd/errors.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/chat/links.dart';
import 'package:agentd_app/src/ui/fakes/sample_data.dart';
import 'package:agentd_app/src/ui/screens/chat_tab.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers.dart';

AgentSession _session() =>
    sampleSessions(DateTime.now()).firstWhere((s) => s.name == 'pando@agentd');

Future<Fakes> _pumpChat(
  WidgetTester tester, {
  List<ChatItem> items = const [],
  Fakes? fakes,
  List<Override> extra = const [],
}) {
  final s = _session();
  return pumpUi(
    tester,
    Scaffold(
      body: ChatTab(
        session: s,
        view: SessionView(session: s, items: items),
        composerFocus: FocusNode(),
        onOpenMailbox: () {},
      ),
    ),
    fakes: fakes,
    extraOverrides: extra,
  );
}

void main() {
  setUp(setUpUiTests);

  testWidgets('agent table renders cells; text around stays', (tester) async {
    await _pumpChat(
      tester,
      items: const [
        ChatItem(
          role: ChatRole.agent,
          text: 'Antes\n┌──────────┬───────────┐\n│ Columna  │ Valor     │\n├──────────┼───────────┤\n│ uno      │ texto que │\n│          │ sigue     │\n└──────────┴───────────┘\nDespués',
        ),
      ],
    );
    expect(find.byKey(const ValueKey('chat-table')), findsOneWidget);
    expect(find.text('Columna'), findsOneWidget);
    expect(find.text('texto que sigue'), findsOneWidget);
    expect(find.textContaining('Antes'), findsOneWidget);
    expect(find.textContaining('Después'), findsOneWidget);
    expect(find.textContaining('┌'), findsNothing);
  });

  testWidgets('link tap calls the injected launcher', (tester) async {
    final opened = <Uri>[];
    await _pumpChat(
      tester,
      items: const [
        ChatItem(role: ChatRole.agent, text: 'Abre https://example.com/docs.'),
      ],
      extra: [
        urlLauncherProvider.overrideWithValue((u) async {
          opened.add(u);
          return true;
        }),
      ],
    );
    final rich = tester.widget<RichText>(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains('example.com'),
      ),
    );
    TapGestureRecognizer? rec;
    rich.text.visitChildren((s) {
      if (s is TextSpan && s.recognizer is TapGestureRecognizer) {
        rec = s.recognizer as TapGestureRecognizer;
      }
      return true;
    });
    expect(rec, isNotNull);
    rec!.onTap!();
    await tester.pump();
    expect(opened.single.toString(), 'https://example.com/docs');
  });

  const cases = {
    AgentdErrorCode.busy: 'Hay texto pendiente',
    AgentdErrorCode.notReady: 'El agente está trabajando',
    AgentdErrorCode.verifyFailed: 'no mostró el texto pegado',
    AgentdErrorCode.conflict: 'La pantalla del agente cambió',
    AgentdErrorCode.timeout: 'El agente no responde',
    '': 'No se pudo enviar',
  };
  for (final e in cases.entries) {
    testWidgets('send error "${e.key}" toast', (tester) async {
      final f = Fakes();
      f.sessions.promptError = AgentdError('x', code: e.key);
      await _pumpChat(tester, fakes: f);
      await tester.enterText(find.byKey(const ValueKey('composer')), 'hola');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining(e.value), findsOneWidget);
    });
  }

  test('busy reasons get their own message', () {
    const reasons = {
      'input': 'ya tiene texto en su entrada',
      'draft': 'borrador sin enviar',
      'human': 'Acabas de teclear',
      'lock': 'recibiendo otra entrada',
    };
    for (final r in reasons.entries) {
      expect(sendErrorMessage(AgentdError('x', code: AgentdErrorCode.busy, data: {'reason': r.key})), contains(r.value));
    }
    expect(sendErrorMessage(const AgentdError('x', code: AgentdErrorCode.busy)), contains('Hay texto pendiente'));
  });
}
