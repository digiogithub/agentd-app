// Projects, terminal-only sessions, terminate and the folder browser.

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/fakes/fake_repositories.dart';
import 'package:agentd_app/src/ui/fakes/sample_data.dart';
import 'package:agentd_app/src/ui/format.dart';
import 'package:agentd_app/src/ui/providers.dart';
import 'package:agentd_app/src/ui/screens/agents_screen.dart';
import 'package:agentd_app/src/ui/screens/folder_browser_screen.dart';
import 'package:agentd_app/src/ui/screens/new_session_screen.dart';
import 'package:agentd_app/src/ui/screens/session_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

Finder rich(String t) => find.textContaining(t, findRichText: true);

void main() {
  setUp(setUpUiTests);

  group('groupByProject', () {
    test(
      'groups by host + directory, attention first, sessions ordered inside',
      () {
        final now = DateTime(2026, 11, 16, 12);
        final groups = groupByProject(sampleSessions(now));
        expect(
          groups.first.label,
          '~/src/webapp',
        ); // claude@webapp waits for an answer
        expect(groups.first.hostId, 'estudio');
        // Same directory on another host is another group.
        expect(groups.where((g) => g.label == '~/src/webapp'), hasLength(2));
        // A session with no cwd and no project: "Sin proyecto".
        final none = groups.singleWhere((g) => !g.hasProject);
        expect(none.label, noProjectLabel);
        expect(none.sessions.single.name, 'main');
        // Groups with something to answer come before the others.
        final firstQuiet = groups.indexWhere((g) => g.needsAnswer == 0);
        expect(
          groups.skip(firstQuiet).every((g) => g.needsAnswer == 0),
          isTrue,
        );
      },
    );

    test('inside a group: needs answer, working, then by last update', () {
      final t = DateTime(2026, 11, 16, 12);
      AgentSession s(
        String n,
        AgentStatus st,
        int ago, {
        bool pending = false,
      }) => AgentSession(
        hostId: 'h',
        source: SessionSource.agentd,
        name: n,
        cwd: '/home/u/src/api/',
        status: st,
        updatedAt: t.subtract(Duration(minutes: ago)),
        pending: pending ? const PendingInteraction(question: 'q') : null,
      );
      final g = groupByProject([
        s('old', AgentStatus.idle, 50),
        s('new', AgentStatus.idle, 1),
        s('work', AgentStatus.working, 30),
        s('ask', AgentStatus.waiting, 40, pending: true),
      ]).single;
      expect(g.path, '/home/u/src/api'); // trailing slash removed
      expect(g.label, '~/src/api');
      expect(g.sessions.map((x) => x.name), ['ask', 'work', 'new', 'old']);
    });

    test('shortPath replaces the home directory', () {
      expect(shortPath('/home/ana/src/api'), '~/src/api');
      expect(shortPath('/Users/ana'), '~');
      expect(shortPath('/srv/www'), '/srv/www');
      expect(shortPath('/homework/x'), '/homework/x');
    });
  });

  group('settings', () {
    test(
      'grouping defaults to project and old stored settings still parse',
      () {
        expect(const AppSettings().agentsGrouping, AgentsGrouping.project);
        final old = appSettingsFromJson({'theme': 'light', 'notifyExit': true});
        expect(old.agentsGrouping, AgentsGrouping.project);
        expect(old.theme, ThemeChoice.light);
        expect(
          appSettingsFromJson({'agentsGrouping': 'bogus'}).agentsGrouping,
          AgentsGrouping.project,
        );
        final back = appSettingsFromJson(
          const AppSettings(agentsGrouping: AgentsGrouping.status).toJson(),
        );
        expect(back.agentsGrouping, AgentsGrouping.status);
      },
    );
  });

  group('agents by project', () {
    testWidgets(
      'default view has project headers; the toggle switches and persists',
      (tester) async {
        final store = MemorySettingsStore();
        await pumpUi(
          tester,
          const Scaffold(body: AgentsScreen()),
          height: 1400,
          extraOverrides: [settingsStoreProvider.overrideWithValue(store)],
        );
        expect(rich('~/src/webapp'), findsWidgets);
        expect(
          rich('estudio'),
          findsWidgets,
        ); // more than one host: the host is named
        expect(rich(noProjectLabel), findsOneWidget);
        expect(find.text('NECESITAN RESPUESTA · 2'), findsNothing);
        expect(
          find.bySemanticsLabel('Nueva sesión en ~/src/webapp'),
          findsNWidgets(2),
        );

        await tester.tap(find.text('Estado'));
        await settle(tester);
        expect(find.text('NECESITAN RESPUESTA · 2'), findsOneWidget);
        expect((await store.load()).agentsGrouping, AgentsGrouping.status);

        await tester.tap(find.text('Proyecto'));
        await settle(tester);
        expect(find.text('NECESITAN RESPUESTA · 2'), findsNothing);
        expect((await store.load()).agentsGrouping, AgentsGrouping.project);
      },
    );

    testWidgets(
      '+ in a group opens New session with host and project prefilled',
      (tester) async {
        await pumpUi(
          tester,
          const Scaffold(body: AgentsScreen()),
          height: 1400,
        );
        await tester.tap(find.bySemanticsLabel('Nueva sesión en ~/src/agentd'));
        await settle(tester);
        expect(find.text('Nueva sesión'), findsWidgets);
        expect(
          find.text('~/src/agentd'),
          findsOneWidget,
        ); // selected project pill
        expect(rich('Se creará claude@agentd'), findsOneWidget); // "Se creará"
        expect(find.text('estudio'), findsOneWidget); // host
      },
    );

    testWidgets('long press on a row terminates after confirming', (
      tester,
    ) async {
      final f = await pumpUi(
        tester,
        const Scaffold(body: AgentsScreen()),
        height: 1400,
      );
      await tester.longPress(find.text('pando@agentd'));
      await settle(tester);
      expect(find.text('Forzar cierre y borrar la sesión'), findsOneWidget);
      await tester.tap(find.text('Terminar'));
      await settle(tester);
      expect(
        find.text('¿Forzar cierre y borrar pando@agentd?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancelar'));
      await settle(tester);
      expect(f.sessions.calls.where((c) => c.method == 'terminate'), isEmpty);

      await tester.longPress(find.text('pando@agentd'));
      await settle(tester);
      await tester.tap(find.text('Terminar'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Terminar'));
      await settle(tester);
      expect(
        f.sessions.calls.singleWhere((c) => c.method == 'terminate').session,
        'pando@agentd',
      );
      expect(find.text('pando@agentd'), findsNothing);
    });

    testWidgets('a failed terminate keeps the session and tells why', (
      tester,
    ) async {
      final f = await pumpUi(
        tester,
        const Scaffold(body: AgentsScreen()),
        height: 1400,
      );
      f.sessions.terminateError = StateError('boom');
      await tester.longPress(find.text('pando@agentd'));
      await settle(tester);
      await tester.tap(find.text('Terminar'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Terminar'));
      await settle(tester);
      expect(find.text('No se pudo terminar la sesión'), findsOneWidget);
      expect(find.text('pando@agentd'), findsOneWidget);
    });
  });

  group('terminate from the session screen', () {
    Future<Fakes> open(
      WidgetTester tester,
      String name, {
      SessionTab? tab,
    }) async {
      final s = sampleSessions(DateTime.now())
          .firstWhere((s) => s.name == name);
      final f = await pumpUi(
        tester,
        Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (_) => SessionScreen(session: s, initialTab: tab),
                ),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
        height: 1300,
      );
      await tester.tap(find.text('abrir'));
      await settle(tester);
      return f;
    }

    testWidgets('Terminar in the menu confirms, terminates and goes back', (
      tester,
    ) async {
      final f = await open(tester, 'codex@api');
      await tester.tap(find.bySemanticsLabel('Más acciones'));
      await settle(tester);
      await tester.tap(find.text('Terminar'));
      await settle(tester);
      expect(find.text('¿Forzar cierre y borrar codex@api?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Terminar'));
      await settle(tester);
      expect(
        f.sessions.calls.singleWhere((c) => c.method == 'terminate').session,
        'codex@api',
      );
      expect(find.text('abrir'), findsOneWidget); // back on the previous screen
    });

    testWidgets('a terminal-only session has the action too', (tester) async {
      final f = await open(tester, 'main');
      await tester.tap(find.bySemanticsLabel('Más acciones'));
      await settle(tester);
      expect(
        find.text('Ver buzón del host'),
        findsNothing,
      ); // no agentd actions
      await tester.tap(find.text('Terminar'));
      await settle(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Terminar'));
      await settle(tester);
      expect(
        f.sessions.calls.singleWhere((c) => c.method == 'terminate').session,
        'main',
      );
    });
  });

  group('new session', () {
    testWidgets(
      'Solo terminal hides the agents and launches the shell harness',
      (tester) async {
        final f = await pumpUi(tester, const NewSessionScreen(), height: 1400);
        await settle(tester);
        expect(find.text('Claude Code'), findsOneWidget);
        expect(
          find.text('Shell'),
          findsNothing,
        ); // no longer mixed with the agents
        await tester.tap(find.text('Solo terminal'));
        await settle(tester);
        expect(find.text('Claude Code'), findsNothing);
        expect(find.text('PRIMER MENSAJE (OPCIONAL)'), findsNothing);
        expect(
          find.textContaining('Shell de login dentro de agentd'),
          findsOneWidget,
        );
        expect(rich('shell@webapp'), findsOneWidget);
        await tester.tap(find.text('zellij'));
        await settle(tester);
        expect(
          find.textContaining('shell por defecto de zellij'),
          findsOneWidget,
        );

        await tester.tap(find.text('agentd').first);
        await settle(tester);
        await tester.tap(find.text('Lanzar'));
        await settle(tester);
        final call = f.sessions.calls.singleWhere((c) => c.method == 'launch');
        expect(call.session, 'shell@webapp');
        expect((call.arg as Map)['where'], 'agentd');
        expect((call.arg as Map)['firstPrompt'], isNull);
      },
    );

    testWidgets(
      'Explorar opens the browser and the chosen folder becomes the project',
      (tester) async {
        final f = await pumpUi(
          tester,
          const NewSessionScreen(hostId: 'estudio'),
          height: 1400,
        );
        await settle(tester);
        await tester.tap(find.text('Explorar…'));
        await settle(tester);
        expect(find.text('Elegir carpeta'), findsOneWidget);
        expect(f.sessions.calls, isEmpty);
        // Starts in the home directory.
        expect(find.text('src'), findsOneWidget);
        expect(find.text('.config'), findsNothing);

        await tester.tap(find.text('Mostrar ocultas'));
        await settle(tester);
        expect(find.text('.config'), findsOneWidget);

        // Leave the home directory through the breadcrumb.
        await tester.tap(find.bySemanticsLabel('Carpeta raíz'));
        await settle(tester);
        expect(find.text('srv'), findsOneWidget);
        expect(find.text('root'), findsOneWidget);
        await tester.tap(find.text('root')); // no permission: not clickable
        await settle(tester);
        expect(find.text('Usar esta carpeta'), findsOneWidget);
        await tester.tap(find.text('srv'));
        await settle(tester);
        expect(find.text('www'), findsOneWidget);
        await tester.tap(find.text('Usar esta carpeta'));
        await settle(tester, frames: 14);

        expect(find.text('Elegir carpeta'), findsNothing);
        expect(find.text('/srv'), findsOneWidget); // pill
        expect(rich('claude@srv'), findsOneWidget);
      },
    );
  });

  group('folder browser', () {
    testWidgets('Inicio, Subir and failures', (tester) async {
      final fakes = await pumpUi(
        tester,
        const FolderBrowserScreen(
          hostId: 'estudio',
          initialPath: '/home/demo/src',
        ),
        height: 1000,
      );
      await settle(tester);
      expect(find.text('webapp'), findsOneWidget);
      await tester.tap(find.text('Subir'));
      await settle(tester);
      expect(fakes.sessions.listed.last, '/home/demo');
      expect(find.text('docs'), findsOneWidget);
      await tester.tap(find.text('Subir'));
      await settle(tester);
      expect(find.text('other'), findsOneWidget);
      await tester.tap(find.text('Subir'));
      await settle(tester);
      expect(find.text('root'), findsOneWidget);
      await tester.tap(find.text('Inicio (~)'));
      await settle(tester);
      expect(find.text('Música'), findsOneWidget);
      expect(FakeSessionsRepository.fakeHome, '/home/demo');
    });

    testWidgets('a missing start folder shows the error and a way back', (
      tester,
    ) async {
      await pumpUi(
        tester,
        const FolderBrowserScreen(hostId: 'estudio', initialPath: '/nope'),
        height: 1000,
      );
      await settle(tester);
      expect(find.text('No existe'), findsOneWidget);
      await tester.tap(find.text('Ir a Inicio'));
      await settle(tester);
      expect(find.text('src'), findsOneWidget);
    });
  });
}
