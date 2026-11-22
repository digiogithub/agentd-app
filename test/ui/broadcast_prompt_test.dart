// Selection mode of the Agents list: pick several sessions and send one
// prompt to all of them.

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/screens/agents_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

Finder _row(String key) => find.byKey(ValueKey('pick-$key'));
const _bar = ValueKey('broadcast-bar');

Future<Fakes> _pump(WidgetTester tester, {Fakes? fakes}) async {
  final f = await pumpUi(tester, const Scaffold(body: AgentsScreen()), fakes: fakes, height: 1400);
  await tester.tap(find.bySemanticsLabel('Seleccionar varios'));
  await tester.pump();
  return f;
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('broadcast-text')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('broadcast-send')));
  await settle(tester);
}

Iterable<String> _prompted(Fakes f) => f.sessions.calls.where((c) => c.method == 'prompt').map((c) => c.session);

void main() {
  setUp(setUpUiTests);

  testWidgets('picks one host and sends the prompt to each of its agents', (tester) async {
    final f = await _pump(tester);
    expect(find.byKey(_bar), findsOneWidget);
    expect(find.text('Nueva sesión'), findsNothing);
    expect(find.text('Elige a quién enviar el prompt'), findsOneWidget);
    expect(find.text('Mostrados · 6'), findsOneWidget);
    expect(find.text('vps-hetzner · 2'), findsOneWidget);

    await tester.ensureVisible(find.text('estudio · 4'));
    await tester.tap(find.text('estudio · 4'));
    await tester.pump();
    expect(find.text('4 agentes seleccionados'), findsOneWidget);
    expect(find.text('Enviar a 4'), findsOneWidget);

    await _send(tester, '  haz commit  ');
    expect(_prompted(f).toSet(), {'claude@webapp', 'pando@agentd', 'claude@docs', 'pando@pips'});
    expect(f.sessions.calls.where((c) => c.method == 'prompt').every((c) => c.arg == 'haz commit'), isTrue);
    expect(find.text('Prompt enviado a 4 agentes'), findsOneWidget);
    // Everything was delivered: the mode ends.
    expect(find.byKey(_bar), findsNothing);
    expect(find.text('Nueva sesión'), findsOneWidget);
  });

  testWidgets('a row toggles its checkbox and does not open the session', (tester) async {
    final f = await _pump(tester);
    await tester.tap(_row('vps-hetzner/agentd/codex@api'));
    await settle(tester);
    expect(find.text('1 agente seleccionado'), findsOneWidget);
    expect(find.text('Responder'), findsNothing);
    expect(find.text('Agentes'), findsOneWidget);
    await tester.tap(_row('vps-hetzner/agentd/codex@api'));
    await tester.pump();
    expect(find.text('Elige a quién enviar el prompt'), findsOneWidget);
    expect(f.sessions.calls, isEmpty);
  });

  testWidgets('zellij rows are shown disabled', (tester) async {
    await _pump(tester);
    expect(find.text('portatil · no admite prompts desde aquí'), findsOneWidget);
    await tester.tap(_row('portatil/zellij/main'));
    await tester.pump();
    expect(find.text('Elige a quién enviar el prompt'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pick-all')));
    await tester.pump();
    expect(find.text('6 agentes seleccionados'), findsOneWidget);
  });

  testWidgets('quick picks follow the filter; none and leaving clear the selection', (tester) async {
    await _pump(tester);
    await tester.ensureVisible(find.text('Trabajando · 2'));
    await tester.tap(find.text('Trabajando · 2'));
    await tester.pump();
    // The zellij session works too, but only the agentd one can be picked.
    expect(find.text('Mostrados · 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-host:estudio')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pick-all')));
    await tester.pump();
    expect(find.text('1 agente seleccionado'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('pick-none')));
    await tester.tap(find.byKey(const ValueKey('pick-none')));
    await tester.pump();
    expect(find.text('Elige a quién enviar el prompt'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pick-all')));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Salir de la selección'));
    await tester.pump();
    expect(find.byKey(_bar), findsNothing);
    await tester.tap(find.bySemanticsLabel('Seleccionar varios'));
    await tester.pump();
    expect(find.text('Elige a quién enviar el prompt'), findsOneWidget);
  });

  testWidgets('a view-only relay host cannot be picked', (tester) async {
    final fakes = Fakes();
    await fakes.hosts.save(
      const HostConfig(
        id: 'vps-hetzner',
        name: 'vps-hetzner',
        host: 'relay.example',
        port: 0,
        user: '',
        transport: HostTransport.relay,
        relay: RelayHostInfo(
          relayUrl: 'https://relay.example',
          route: 'abcdefghijklmnopqrstuvwx27',
          hostKey: 'k',
          deviceId: 'dabc',
          scope: RelayScope.view,
          kind: 'owner',
          label: 'vps-hetzner',
        ),
      ),
    );
    final f = await _pump(tester, fakes: fakes);
    await settle(tester);
    expect(find.text('Mostrados · 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('pick-host:vps-hetzner')), findsNothing);
    expect(find.text('vps-hetzner · solo lectura en este dispositivo'), findsNWidgets(2));
    await tester.tap(_row('vps-hetzner/agentd/codex@api'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pick-all')));
    await tester.pump();
    await _send(tester, 'estado');
    expect(_prompted(f), hasLength(4));
    expect(_prompted(f), isNot(contains('codex@api')));
  });

  testWidgets('a refused session stays selected and is named', (tester) async {
    final fakes = Fakes();
    fakes.sessions.promptErrors['codex@api'] = StateError('busy');
    final f = await _pump(tester, fakes: fakes);
    await tester.tap(find.byKey(const ValueKey('pick-all')));
    await tester.pump();
    await _send(tester, 'estado');
    expect(_prompted(f), hasLength(6));
    expect(find.text('Prompt enviado a 5 agentes'), findsOneWidget);
    expect(find.text('No se pudo enviar a codex@api: No se pudo enviar'), findsOneWidget);
    // Still in selection mode, with the refused session and the draft kept.
    expect(find.text('1 agente seleccionado'), findsOneWidget);
    expect(find.text('Enviar a 1'), findsOneWidget);
    expect(find.text('estado'), findsOneWidget);
  });
}
