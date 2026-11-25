// Push in the app: the token is registered on the fakes' agentd hosts, a
// tapped permission push opens the session's chat, a question push the
// Panel, and Ajustes > Notificaciones push turns it off.

import 'dart:async';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/platform/push.dart';
import 'package:agentd_app/src/ui/app.dart';
import 'package:agentd_app/src/ui/fakes/fake_repositories.dart';
import 'package:agentd_app/src/ui/providers.dart';
import 'package:agentd_app/src/ui/screens/session_screen.dart';
import 'package:agentd_app/src/ui/widgets/bottom_nav.dart';
import 'package:agentd_app/src/ui/widgets/common.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

class _Messaging implements PushMessaging {
  final taps = StreamController<PushOpen>.broadcast();
  @override
  Future<bool> init() async => true;
  @override
  Future<void> requestPermission() async {}
  @override
  Future<String?> token() async => 'tok';
  @override
  Stream<String> get tokenRefresh => const Stream.empty();
  @override
  Stream<PushOpen> get foreground => const Stream.empty();
  @override
  Stream<PushOpen> get opens => taps.stream;
  @override
  Future<PushOpen?> initialOpen() async => null;
}

Future<(_Messaging, FakePushRepository)> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 1600) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final m = _Messaging();
  final repo = FakePushRepository();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...Fakes().overrides, pushMessagingProvider.overrideWithValue(m), pushRepositoryProvider.overrideWithValue(repo)],
      child: const AgentdApp(),
    ),
  );
  await settle(tester);
  return (m, repo);
}

int _tab(WidgetTester tester) => tester.widget<AppBottomNav>(find.byType(AppBottomNav)).index;

void main() {
  setUp(setUpUiTests);

  testWidgets('registers on the online agentd hosts with their saved ids', (tester) async {
    final (_, repo) = await _pumpApp(tester);
    expect(repo.registered.keys, containsAll(['estudio', 'vps-hetzner']));
    expect(repo.registered.containsKey('portatil'), isFalse);
  });

  testWidgets('a permission push opens that chat; a question push the Panel', (tester) async {
    final (m, _) = await _pumpApp(tester);
    await tester.tap(find.text('Ajustes').last);
    await settle(tester);
    expect(_tab(tester), 4);

    m.taps.add(const PushOpen(hostId: 'estudio', session: 'claude@webapp', reason: 'permission'));
    await settle(tester);
    expect(find.byType(SessionScreen), findsOneWidget);
    expect(tester.widget<SessionScreen>(find.byType(SessionScreen)).session.name, 'claude@webapp');

    m.taps.add(const PushOpen(hostId: 'estudio', session: 'claude@webapp', reason: 'question', messageId: 3));
    await settle(tester, frames: 20);
    expect(find.byType(SessionScreen), findsNothing);
    expect(_tab(tester), 0);
  });

  testWidgets('Notificaciones push off unregisters every host', (tester) async {
    final (_, repo) = await _pumpApp(tester);
    expect(repo.registered, isNotEmpty);
    await tester.tap(find.text('Ajustes').last);
    await settle(tester);
    final sw = find.byKey(const ValueKey('push-switch'));
    await tester.ensureVisible(sw);
    await tester.pump();
    expect(find.text('Notificaciones push'), findsOneWidget);
    await tester.tap(find.descendant(of: sw, matching: find.byType(AppSwitch)));
    await settle(tester);
    expect(repo.registered, isEmpty);
  });
}
