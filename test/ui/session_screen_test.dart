import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/fakes/sample_data.dart';
import 'package:agentd_app/src/ui/screens/session_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import 'helpers.dart';

AgentSession _session(String name) => sampleSessions(DateTime.now()).firstWhere((s) => s.name == name);

void main() {
  setUp(setUpUiTests);

  group('chat', () {
    testWidgets('renders transcript, tools and the question', (tester) async {
      await pumpUi(tester, SessionScreen(session: _session('codex@api')), height: 1300);
      expect(find.text('codex@api'), findsOneWidget);
      expect(find.text('vps-hetzner · ~/src/api · turno 14'), findsOneWidget);
      expect(find.text('Esperando'), findsOneWidget);
      expect(find.text('Añade expiración a los tokens de sesión y migra la base de datos.'), findsOneWidget);
      expect(find.text('PREGUNTA'), findsOneWidget);
      expect(find.text('Migrar ahora con una migración reversible'), findsOneWidget);
      expect(find.text('1 mensaje en cola: se entrega cuando el agente quede libre'), findsOneWidget);

      // Collapsible tool output.
      expect(find.textContaining('api/internal/auth'), findsNothing);
      await tester.tap(find.text('go test ./...'));
      await tester.pump();
      expect(find.textContaining('api/internal/auth'), findsOneWidget);
    });

    testWidgets('Responder sends choose with revision and epoch', (tester) async {
      final f = await pumpUi(tester, SessionScreen(session: _session('codex@api')));
      await tester.tap(find.text('Migrar ahora con una migración reversible'));
      await tester.pump();
      await tester.tap(find.text('Responder'));
      await settle(tester);
      final call = f.sessions.calls.singleWhere((c) => c.method == 'choose');
      expect(call.arg, 'q-now');
      expect(call.revision, 17);
      expect(call.epoch, kEpoch);
      expect(find.text('PREGUNTA'), findsNothing);
      expect(find.text('Trabajando'), findsOneWidget);
    });

    testWidgets('composer sends a prompt', (tester) async {
      final f = await pumpUi(tester, SessionScreen(session: _session('pando@agentd')));
      await tester.enterText(find.byKey(const ValueKey('composer')), 'Sigue con los tests');
      await tester.tap(find.bySemanticsLabel('Enviar'));
      await settle(tester);
      final call = f.sessions.calls.singleWhere((c) => c.method == 'prompt');
      expect(call.arg, 'Sigue con los tests');
      expect(find.text('Sigue con los tests'), findsOneWidget);
    });
  });

  group('terminal', () {
    testWidgets('streams the PTY, sends keys and interrupt', (tester) async {
      final f = await pumpUi(tester, SessionScreen(session: _session('claude@webapp'), initialTab: SessionTab.terminal));
      await settle(tester);
      expect(find.byType(TerminalView), findsOneWidget);
      expect(f.sessions.calls.where((c) => c.method == 'terminal').single.arg, false);
      expect(find.text('Control: tus teclas llegan al agente y el PTY se ajusta a esta pantalla.'), findsOneWidget);
      // Control mode: the PTY takes the view's size.
      final pty = f.sessions.ptys.single;
      expect(pty.resizes, isNotEmpty);
      expect(pty.resizes.last.$1, greaterThan(10));

      // A size change (soft keyboard, rotation) is sent once, coalesced.
      final before = pty.resizes.length;
      tester.view.physicalSize = Size(tester.view.physicalSize.width, tester.view.physicalSize.height * 0.7);
      addTearDown(tester.view.resetPhysicalSize);
      await settle(tester);
      expect(pty.resizes.length, before + 1);
      expect(pty.resizes.last.$2, lessThan(pty.resizes[before - 1].$2));

      await tester.tap(find.bySemanticsLabel('Escape'));
      await tester.tap(find.bySemanticsLabel('Arriba'));
      await tester.pump();
      expect(f.sessions.calls.where((c) => c.method == 'keys').map((c) => c.arg).toList(), [
        ['esc'],
        ['up'],
      ]);

      // Line input goes to the PTY with a CR.
      await tester.enterText(find.byKey(const ValueKey('terminal-input')), 'ls');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(f.sessions.ptys.single.written, contains('ls\r'));

      await tester.tap(find.text('Interrumpir'));
      await settle(tester);
      expect(f.sessions.calls.where((c) => c.method == 'interrupt'), hasLength(1));
    });

    testWidgets('observe never resizes the PTY', (tester) async {
      final f = await pumpUi(tester, SessionScreen(session: _session('claude@webapp'), initialTab: SessionTab.terminal));
      await settle(tester);
      await tester.tap(find.text('Control'));
      await settle(tester);
      final pty = f.sessions.ptys.last;
      expect(f.sessions.calls.where((c) => c.method == 'terminal').last.arg, true);
      expect(pty.resizes, isEmpty);
    });

    testWidgets('ctrl arms a ctrl-letter from the input', (tester) async {
      final f = await pumpUi(tester, SessionScreen(session: _session('claude@webapp'), initialTab: SessionTab.terminal));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('Control'));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('terminal-input')), 'c');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(f.sessions.calls.where((c) => c.method == 'keys').single.arg, ['ctrl-c']);
    });

    testWidgets('Observar reattaches read-only', (tester) async {
      final f = await pumpUi(tester, SessionScreen(session: _session('claude@webapp'), initialTab: SessionTab.terminal));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('Cambiar modo de control'));
      await settle(tester);
      expect(find.text('Observar: solo lectura, nadie ve tus pulsaciones.'), findsOneWidget);
      expect(f.sessions.calls.where((c) => c.method == 'terminal').map((c) => c.arg), [false, true]);
      expect(f.sessions.ptys.first.closed, isTrue);
    });

    testWidgets('zellij sessions open on the terminal', (tester) async {
      await pumpUi(tester, SessionScreen(session: _session('main')));
      await settle(tester);
      expect(find.text('zellij · main'), findsOneWidget);
      expect(find.byType(TerminalView), findsOneWidget);
    });
  });
}
