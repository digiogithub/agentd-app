// Chat composer: the buttons move below the input while it has the focus,
// and a stop button (Esc) shows while the agent works.

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/screens/chat_tab.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers.dart';

AgentSession _session(AgentStatus status) =>
    AgentSession(hostId: 'h1', source: SessionSource.agentd, name: 'claude@api', status: status);

Future<Fakes> _pump(WidgetTester tester, AgentStatus status, FocusNode focus) {
  final s = _session(status);
  return pumpUi(
    tester,
    Scaffold(
      body: ChatTab(session: s, view: SessionView(session: s, items: const []), composerFocus: focus, onOpenMailbox: () {}),
    ),
  );
}

void main() {
  setUp(setUpUiTests);

  testWidgets('focus moves dictation, attach and send to a bar below the full-width input', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _pump(tester, AgentStatus.idle, focus);
    final composer = find.byKey(const ValueKey('composer'));
    final send = find.bySemanticsLabel('Enviar');
    expect(find.byKey(const ValueKey('composer-bar')), findsNothing);
    final rowWidth = tester.getSize(composer).width;
    expect(tester.getTopLeft(send).dy, lessThan(tester.getBottomLeft(composer).dy));

    await tester.tap(composer);
    await tester.pump();
    await tester.enterText(composer, 'hola');
    await tester.pump();
    expect(find.byKey(const ValueKey('composer-bar')), findsOneWidget);
    expect(tester.getSize(composer).width, greaterThan(rowWidth + 80));
    expect(tester.getTopLeft(send).dy, greaterThanOrEqualTo(tester.getBottomLeft(composer).dy));
    expect(tester.getTopLeft(find.bySemanticsLabel('Adjuntar imagen')).dy, greaterThanOrEqualTo(tester.getBottomLeft(composer).dy));
    // The text survives the move.
    expect(tester.widget<TextField>(composer).controller!.text, 'hola');
    expect(find.byKey(const ValueKey('stop-button')), findsNothing, reason: 'idle agent: nothing to stop');

    focus.unfocus();
    await tester.pump();
    expect(find.byKey(const ValueKey('composer-bar')), findsNothing);
  });

  testWidgets('while the agent works a stop button sends Esc (interrupt)', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final f = await _pump(tester, AgentStatus.working, focus);
    await tester.tap(find.byKey(const ValueKey('stop-button')));
    await tester.pumpAndSettle();
    expect(f.sessions.calls.where((c) => c.method == 'interrupt').map((c) => c.session), ['claude@api']);
    // Also in the bar of the focused composer.
    await tester.tap(find.byKey(const ValueKey('composer')));
    await tester.pump();
    expect(find.descendant(of: find.byKey(const ValueKey('composer-bar')), matching: find.byKey(const ValueKey('stop-button'))), findsOneWidget);
  });
}
