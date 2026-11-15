import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/screens/add_host_screen.dart';
import 'package:agentd_app/src/ui/screens/hosts_screen.dart';
import 'package:agentd_app/src/ui/screens/new_session_screen.dart';
import 'package:agentd_app/src/ui/screens/provision_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

void main() {
  setUp(setUpUiTests);

  group('new session', () {
    testWidgets('renders host, targets, agents and launches', (tester) async {
      final f = await pumpUi(tester, const NewSessionScreen(), height: 1100);
      expect(find.text('Nueva sesión'), findsOneWidget);
      expect(find.text('estudio'), findsOneWidget);
      expect(find.text('agentd 0.6.2 · SSH'), findsOneWidget);
      expect(find.textContaining('Recomendado: vista chat'), findsOneWidget);
      expect(find.text('instalado · 2.4'), findsOneWidget);
      expect(find.text('Instalar…'), findsNWidgets(2)); // opencode, gemini
      expect(find.text('Se creará claude@webapp'), findsOneWidget);

      await tester.tap(find.text('Codex'));
      await tester.tap(find.text('api'));
      await tester.pump();
      expect(find.text('Se creará codex@api'), findsOneWidget);

      await tester.tap(find.text('zellij'));
      await tester.pump();
      expect(find.textContaining('Pane nuevo en la sesión zellij'), findsOneWidget);
      await tester.tap(find.text('agentd').first); // the segment, not the project chip
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Arregla el login');
      await tester.tap(find.text('Lanzar'));
      await settle(tester);
      final call = f.sessions.calls.singleWhere((c) => c.method == 'launch');
      expect(call.session, 'codex@api');
      expect(call.arg, {'host': 'estudio', 'where': 'agentd', 'firstPrompt': 'Arregla el login'});
      expect(find.text('Arrancando'), findsOneWidget); // pushed into the session
    });

    testWidgets('a missing agent opens provisioning', (tester) async {
      await pumpUi(tester, const NewSessionScreen(), height: 1100);
      await tester.tap(find.text('opencode'));
      await settle(tester);
      expect(find.text('Preparar estudio'), findsOneWidget);
      expect(find.text('Se instalará'), findsOneWidget);
    });
  });

  group('hosts', () {
    testWidgets('shows states and retries offline hosts', (tester) async {
      final f = await pumpUi(tester, const Scaffold(body: HostsScreen()));
      expect(find.text('3 en línea · 1 sin agentd'), findsOneWidget);
      expect(find.text('jose@estudio.local · SSH'), findsOneWidget);
      expect(find.text('agentd 0.6.2'), findsOneWidget);
      expect(find.text('claude · codex · pando'), findsOneWidget);
      expect(find.text('zellij · main'), findsOneWidget);
      expect(find.text('Sin conexión'), findsOneWidget);
      await tester.tap(find.text('Reintentar'));
      await settle(tester);
      expect(f.hosts.connected, ['raspberry']);
    });

    testWidgets('install button opens provisioning for the host', (tester) async {
      await pumpUi(tester, const Scaffold(body: HostsScreen()));
      await tester.tap(find.text('Instalar agentd en portatil'));
      await settle(tester);
      expect(find.text('Preparar portatil'), findsOneWidget);
    });
  });

  group('add host', () {
    testWidgets('saves, connects and goes to provisioning', (tester) async {
      final f = await pumpUi(tester, const AddHostScreen(), height: 1100);
      await settle(tester);
      expect(find.text('Escanear QR'), findsOneWidget);
      expect(find.text('Clave generada en este móvil'), findsOneWidget);
      expect(find.text('Copiar clave pública'), findsOneWidget);
      expect(find.textContaining('ssh-ed25519'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'mini');
      await tester.enterText(fields.at(1), '10.0.0.5');
      await tester.enterText(fields.at(3), 'ana');
      await tester.tap(find.text('Contraseña'));
      await tester.pump();
      expect(find.text('Copiar clave pública'), findsNothing);

      // Without a password nothing happens.
      await tester.tap(find.text('Conectar y detectar'));
      await tester.pump();
      expect(find.text('Escribe la contraseña para instalar la clave'), findsOneWidget);
      expect(f.hosts.connected, isEmpty);

      await tester.enterText(find.byType(TextField).last, 's3cret');
      await tester.tap(find.text('Conectar y detectar'));
      await settle(tester);
      final saved = f.hosts.hosts.singleWhere((h) => h.config.id == 'mini');
      expect(saved.config.host, '10.0.0.5');
      expect(saved.config.user, 'ana');
      // The password only installed the key: the host now uses it.
      expect(saved.config.auth, AuthKind.generatedKey);
      expect(f.hosts.enrolled, ['mini']);
      expect(f.hosts.connected, ['mini']);
      expect(find.text('Preparar mini'), findsOneWidget);
    });

    testWidgets('refuses an empty form', (tester) async {
      final f = await pumpUi(tester, const AddHostScreen(), height: 1100);
      await tester.tap(find.text('Conectar y detectar'));
      await tester.pump();
      expect(find.text('Rellena host, puerto y usuario'), findsOneWidget);
      expect(f.hosts.connected, isEmpty);
    });
  });

  group('provision', () {
    testWidgets('detects, shows the plan and streams the install', (tester) async {
      final f = await pumpUi(tester, const ProvisionScreen(hostId: 'portatil'), height: 1100);
      await settle(tester);
      expect(find.text('Preparar portatil'), findsOneWidget);
      expect(find.text('Linux x86_64 · Pop!_OS 24.04 · systemd de usuario'), findsOneWidget);
      expect(find.text('zellij 0.43'), findsOneWidget);
      expect(find.text('sin agentd'), findsOneWidget);
      expect(find.text('sin tmux'), findsOneWidget);
      expect(find.text('Instalar 1 componente'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Instalar Codex'));
      await tester.pump();
      expect(find.text('Instalar 2 componentes'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Ver los comandos que se ejecutarán por SSH'));
      await tester.pump();
      expect(find.textContaining('npm i -g @openai/codex'), findsOneWidget);
      expect(find.textContaining('systemctl --user enable --now agentd'), findsOneWidget);

      await tester.tap(find.text('Instalar 2 componentes'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Descargando agentd 0.6.2'), findsOneWidget);
      expect(find.text('Instalando…'), findsOneWidget);
      await settle(tester, frames: 20);
      expect(find.text('Instalando codex'), findsOneWidget);
      expect(find.text('Registrando el MCP de agentd'), findsOneWidget);
      expect(find.text('Listo'), findsOneWidget);
      expect(f.provision.installs, 1);
      expect(f.hosts.connected, contains('portatil'));
    });

    testWidgets('turning agentd off leaves nothing to install', (tester) async {
      await pumpUi(tester, const ProvisionScreen(hostId: 'portatil'), height: 1100);
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('Instalar agentd'));
      await tester.pump();
      expect(find.text('Nada que instalar'), findsOneWidget);
    });
  });
}
