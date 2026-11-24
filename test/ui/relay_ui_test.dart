// Relay hosts in the UI: pairing by invite link, scope-aware session screen.

import 'dart:async';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/relay/relay.dart' show RelayError, RelayFailure;
import 'package:agentd_app/src/ui/app.dart';
import 'package:agentd_app/src/ui/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:agentd_app/src/ui/fakes/sample_data.dart';
import 'package:agentd_app/src/ui/screens/add_host_screen.dart';
import 'package:agentd_app/src/ui/screens/hosts_screen.dart';
import 'package:agentd_app/src/ui/screens/qr_scan_screen.dart';
import 'package:agentd_app/src/ui/screens/session_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart' show MobileScannerErrorCode;

import 'helpers.dart';

AgentSession _session(String name) => sampleSessions(DateTime.now()).firstWhere((s) => s.name == name);

const _link =
    'agentd://relay?v=1&u=https%3A%2F%2Frelay.example&r=abcdefghijklmnopqrstuvwx27&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&i=0123456789abcdef&c=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&h=box';

/// Makes [hostId] a relay host with [scope].
Future<Fakes> _relayFakes(String hostId, RelayScope scope) async {
  final f = Fakes();
  await f.hosts.save(
    HostConfig(
      id: hostId,
      name: hostId,
      host: 'relay.example',
      port: 0,
      user: '',
      transport: HostTransport.relay,
      relay: RelayHostInfo(
        relayUrl: 'https://relay.example',
        route: 'abcdefghijklmnopqrstuvwx27',
        hostKey: 'k',
        deviceId: 'dabc',
        scope: scope,
        kind: 'owner',
        label: hostId,
      ),
    ),
  );
  return f;
}

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Más acciones'));
  await settle(tester);
}

void main() {
  setUp(setUpUiTests);

  testWidgets('pairing flow: waiting for approval, then saved', (tester) async {
    final fakes = Fakes();
    fakes.hosts.pairApproval = Completer<void>();
    await pumpUi(tester, const AddHostScreen(relayLink: _link), fakes: fakes, height: 1100);
    expect(find.text('Enlace de invitación'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('relay-device-name')), 'Pixel');
    await tester.tap(find.text('Emparejar'));
    await settle(tester);
    expect(find.byKey(const ValueKey('relay-waiting-approval')), findsOneWidget);
    expect(find.text('Aprueba en el host'), findsOneWidget);
    expect(find.text('Esperando aprobación…'), findsOneWidget);
    fakes.hosts.pairApproval!.complete();
    await settle(tester);
    expect(fakes.hosts.relayPairings, 1);
    final h = fakes.hosts.hosts.firstWhere((h) => h.config.isRelay);
    expect(h.config.name, 'box');
    expect(h.state, HostState.online);
  });

  testWidgets('a bad link is refused before pairing', (tester) async {
    final fakes = Fakes();
    await pumpUi(tester, const AddHostScreen(), fakes: fakes, height: 1100);
    await tester.tap(find.text('Invitación relay'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('relay-link')), 'https://example.com');
    await tester.tap(find.text('Emparejar'));
    await tester.pump();
    expect(find.text('Pega el enlace agentd://relay?… de agentd relay invite'), findsOneWidget);
    expect(fakes.hosts.relayPairings, 0);
  });

  testWidgets('a link pasted with the terminal prefix and line wraps pairs', (tester) async {
    final fakes = Fakes();
    await pumpUi(tester, const AddHostScreen(), fakes: fakes, height: 1100);
    await tester.tap(find.text('Invitación relay'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('relay-link')), 'Link:  ${_link.substring(0, 70)}\n${_link.substring(70)}\nGrant: operate');
    await tester.tap(find.text('Emparejar'));
    await settle(tester);
    expect(fakes.hosts.relayPairings, 1);
    expect(fakes.hosts.hosts.firstWhere((h) => h.config.isRelay).config.name, 'box');
  });

  testWidgets('a scanned QR fills the invite and pairs like a pasted link', (tester) async {
    final fakes = Fakes();
    var scans = 0;
    // What the camera reads is the link itself; here with a line break, as
    // the pasted text may have.
    Future<String?> scan(BuildContext _) async {
      scans++;
      return '${_link.substring(0, 80)}\n${_link.substring(80)}';
    }

    await pumpUi(tester, const AddHostScreen(), fakes: fakes, height: 1300, extraOverrides: [qrScannerProvider.overrideWithValue(scan)]);
    // From the SSH form: the scan switches to the relay form.
    await tester.tap(find.text('Escanear QR'));
    await settle(tester);
    expect(scans, 1);
    expect(find.text('Enlace de invitación'), findsOneWidget);
    expect(fakes.hosts.relayPairings, 0, reason: 'the device name is confirmed first');
    await tester.tap(find.text('Emparejar'));
    await settle(tester);
    expect(fakes.hosts.relayPairings, 1);
    expect(fakes.hosts.hosts.firstWhere((h) => h.config.isRelay).config.name, 'box');
  });

  testWidgets('a QR that is not an invite, or a closed scanner, changes nothing', (tester) async {
    final fakes = Fakes();
    String? result = 'https://example.com/qr';
    await pumpUi(tester, const AddHostScreen(), fakes: fakes, height: 1300, extraOverrides: [qrScannerProvider.overrideWithValue((_) async => result)]);
    await tester.tap(find.text('Invitación relay'));
    await settle(tester);
    await tester.tap(find.text('Escanear QR'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Ese QR no es una invitación de agentd'), findsOneWidget);
    expect(tester.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('relay-link')), matching: find.byType(TextField))).controller!.text, '');
    result = null;
    await settle(tester, frames: 80);
    await tester.tap(find.text('Escanear QR'));
    await settle(tester);
    expect(tester.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('relay-link')), matching: find.byType(TextField))).controller!.text, '');
  });

  testWidgets('scanner screen: ignores other codes, pops with the invite once', (tester) async {
    late void Function(String) emit;
    String? popped;
    var pops = 0;
    await pumpUi(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            popped = await Navigator.of(context).push<String>(
              MaterialPageRoute<String>(
                builder: (_) => QrScanScreen(
                  preview: (_, onCode) {
                    emit = onCode;
                    return const SizedBox.expand();
                  },
                ),
              ),
            );
            pops++;
          },
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.text('Escanear invitación'), findsOneWidget);
    expect(find.textContaining('Apunta al QR'), findsOneWidget);
    emit('WIFI:S:home;T:WPA;P:x;;');
    await settle(tester);
    expect(find.textContaining('no es una invitación de agentd'), findsOneWidget);
    expect(pops, 0);
    // The camera reports the same code on several frames.
    emit(_link);
    emit(_link);
    await settle(tester, frames: 12);
    expect(pops, 1);
    expect(popped, _link);
    expect(find.text('Escanear invitación'), findsNothing);
  });

  test('camera errors have a Spanish text that offers the paste', () {
    for (final c in MobileScannerErrorCode.values) {
      expect(describeScannerError(c), contains('enlace'));
    }
    expect(describeScannerError(MobileScannerErrorCode.permissionDenied), contains('permiso de cámara'));
  });

  testWidgets('host offline at the relay: explicit error that stays, and a retry', (tester) async {
    final fakes = Fakes();
    fakes.hosts.pairError = const RelayError(RelayFailure.hostOffline, 'the host is not connected to the relay');
    await pumpUi(tester, const AddHostScreen(relayLink: _link), fakes: fakes, height: 1300);
    await tester.tap(find.text('Emparejar'));
    await settle(tester);
    expect(find.byKey(const ValueKey('relay-pair-error')), findsOneWidget);
    expect(find.textContaining('El host no está conectado al relay'), findsOneWidget);
    expect(find.textContaining('agentd relay status'), findsOneWidget);
    // No spinner left, the link is kept for the retry.
    expect(find.text('Conectando…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(_link), findsOneWidget);
    await settle(tester, frames: 80); // longer than a toast
    expect(find.byKey(const ValueKey('relay-pair-error')), findsOneWidget);
    fakes.hosts.pairError = null;
    await tester.tap(find.text('Reintentar'));
    await settle(tester);
    expect(find.byKey(const ValueKey('relay-pair-error')), findsNothing);
    expect(fakes.hosts.relayPairings, 1);
  });

  testWidgets('hosts list shows a relay host with its scope', (tester) async {
    final fakes = await _relayFakes('vps-hetzner', RelayScope.operate);
    await pumpUi(tester, const HostsScreen(), fakes: fakes, height: 1300);
    await settle(tester);
    expect(find.text('relay · relay.example'), findsOneWidget);
    expect(find.text('operar'), findsOneWidget);
  });

  testWidgets('view scope: read only chat, observe-only terminal, no Terminar', (tester) async {
    final fakes = await _relayFakes('vps-hetzner', RelayScope.view);
    await pumpUi(tester, SessionScreen(session: _session('codex@api')), fakes: fakes, height: 1300);
    await settle(tester);
    expect(find.byKey(const ValueKey('composer')), findsNothing);
    expect(find.byKey(const ValueKey('read-only-note')), findsOneWidget);
    // The question is shown but cannot be answered.
    expect(find.text('Migrar ahora con una migración reversible'), findsOneWidget);
    await tester.tap(find.text('Migrar ahora con una migración reversible'), warnIfMissed: false);
    await tester.pump();
    await tester.tap(find.text('Responder'), warnIfMissed: false);
    await settle(tester);
    expect(fakes.sessions.calls.where((c) => c.method == 'choose'), isEmpty);
    await _openMore(tester);
    expect(find.text('Terminar'), findsNothing);
    expect(find.text('Interrumpir'), findsNothing);
  });

  testWidgets('view scope terminal attaches as an observer without the mode toggle', (tester) async {
    final fakes = await _relayFakes('estudio', RelayScope.view);
    await pumpUi(
      tester,
      SessionScreen(session: _session('claude@webapp'), initialTab: SessionTab.terminal),
      fakes: fakes,
    );
    await settle(tester);
    // The attach in use is an observer (the host list may arrive after the
    // first frame; the daemon forces observe for view devices anyway).
    expect(fakes.sessions.calls.where((c) => c.method == 'terminal').last.arg, true);
    expect(find.text('Control'), findsNothing);
    expect(find.text('Observar'), findsNothing);
  });

  testWidgets('operate scope: composer without images, no Terminar', (tester) async {
    final fakes = await _relayFakes('estudio', RelayScope.operate);
    await pumpUi(tester, SessionScreen(session: _session('claude@webapp')), fakes: fakes);
    await settle(tester);
    expect(find.byKey(const ValueKey('composer')), findsOneWidget);
    expect(find.bySemanticsLabel('Adjuntar imagen'), findsNothing);
    await _openMore(tester);
    expect(find.text('Terminar'), findsNothing);
    expect(find.text('Interrumpir'), findsOneWidget);
  });

  testWidgets('admin scope: Terminar is offered', (tester) async {
    final fakes = await _relayFakes('estudio', RelayScope.admin);
    await pumpUi(tester, SessionScreen(session: _session('claude@webapp')), fakes: fakes);
    await settle(tester);
    await _openMore(tester);
    expect(find.text('Terminar'), findsOneWidget);
  });

  testWidgets('an agentd://relay link opens Añadir host with the invite', (tester) async {
    tester.view.physicalSize = const Size(390, 1100) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final links = StreamController<Uri>();
    addTearDown(links.close);
    await tester.pumpWidget(ProviderScope(overrides: [...Fakes().overrides, appLinksProvider.overrideWithValue(links.stream)], child: const AgentdApp()));
    await tester.pump();
    links.add(Uri.parse('https://example.com/other'));
    await settle(tester);
    expect(find.text('Enlace de invitación'), findsNothing);
    links.add(Uri.parse(_link));
    await settle(tester);
    expect(find.text('Enlace de invitación'), findsOneWidget);
    expect(find.text(_link), findsOneWidget);
  });
}
