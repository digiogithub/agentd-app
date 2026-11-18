// UI pieces added with the data layer: TOFU dialog, classified permissions,
// SSH shell launch, Proyecto chips from agentd aliases.

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/app.dart';
import 'package:agentd_app/src/ui/providers.dart';
import 'package:agentd_app/src/ui/screens/agents_screen.dart';
import 'package:agentd_app/src/ui/screens/new_session_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

void main() {
  setUp(setUpUiTests);

  testWidgets('a new host key opens the trust dialog and its answer goes back', (tester) async {
    final prompts = HostKeyPrompts();
    final f = Fakes();
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [...f.overrides, hostKeyPromptsProvider.overrideWithValue(prompts)],
        child: const AgentdApp(),
      ),
    );
    await tester.pump();
    const host = HostConfig(id: 'mini', name: 'mini', host: '10.0.0.5', user: 'ana');
    final answer = prompts.ask(host, 'ssh-ed25519', 'SHA256:abcDEF');
    await settle(tester);
    expect(find.text('¿Confiar en mini?'), findsOneWidget);
    expect(find.text('SHA256:abcDEF'), findsOneWidget);
    await tester.tap(find.text('Confiar'));
    await settle(tester);
    expect(await answer, isTrue);
    expect(find.text('¿Confiar en mini?'), findsNothing);

    final second = prompts.ask(host, 'ssh-ed25519', 'SHA256:other');
    await settle(tester);
    await tester.tap(find.text('Cancelar'));
    await settle(tester);
    expect(await second, isFalse);
  });

  test('without a listener new host keys are refused', () async {
    expect(await HostKeyPrompts().ask(const HostConfig(id: 'x', name: 'x', host: 'x', user: 'u'), 'ssh-ed25519', 'SHA256:x'), isFalse);
  });

  testWidgets('the permission card shows the command from the classification', (tester) async {
    await pumpUi(tester, const Scaffold(body: AgentsScreen()), extraOverrides: [initialSettingsProvider.overrideWithValue(const AppSettings(agentsGrouping: AgentsGrouping.status))]);
    expect(find.text('go test ./internal/... -race'), findsOneWidget);
    expect(find.text('Do you want to proceed?'), findsOneWidget);
  });

  testWidgets('SSH shell launches (no "not available" toast) and opens the terminal', (tester) async {
    final f = await pumpUi(tester, const NewSessionScreen(), height: 1100);
    await tester.tap(find.text('SSH'));
    await tester.pump();
    expect(find.textContaining('Shell de login por SSH'), findsOneWidget);
    await tester.tap(find.text('Lanzar'));
    await settle(tester);
    final call = f.sessions.calls.singleWhere((c) => c.method == 'launch');
    expect((call.arg as Map)['where'], 'shell');
    expect(find.textContaining('aún no está disponible'), findsNothing);
    expect(find.text('ssh · ssh-webapp'), findsOneWidget);
    expect(f.sessions.calls.where((c) => c.method == 'terminal'), hasLength(1)); // terminal-only
  });

  testWidgets('Proyecto chips come from the host aliases', (tester) async {
    await pumpUi(tester, const NewSessionScreen(), height: 1100);
    await settle(tester);
    for (final p in ['webapp', 'api', 'agentd', 'docs', 'pips']) {
      expect(find.text(p), findsWidgets, reason: p);
    }
  });
}
