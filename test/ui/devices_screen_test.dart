// Ajustes > Dispositivos: list the devices paired with a host and revoke one
// behind a confirmation.

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/screens/devices_screen.dart';
import 'package:agentd_app/src/ui/screens/settings_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await settle(tester);
}

/// Makes [hostId] a relay host paired as device `dme`.
Future<Fakes> _relayFakes(String hostId, RelayScope scope, {String kind = 'owner'}) async {
  final f = Fakes();
  await f.hosts.save(
    HostConfig(
      id: hostId,
      name: hostId,
      host: 'relay.example',
      port: 0,
      user: '',
      transport: HostTransport.relay,
      relay: RelayHostInfo(relayUrl: 'https://relay.example', route: 'abcdefghijklmnopqrstuvwx27', hostKey: 'k', deviceId: 'dme', scope: scope, kind: kind, label: hostId),
    ),
  );
  return f;
}

void main() {
  setUp(setUpUiTests);

  testWidgets('settings lists the connected agentd hosts and opens their devices', (tester) async {
    await pumpUi(tester, const Scaffold(body: SettingsScreen()), height: 1600);
    await settle(tester);
    expect(find.text('DISPOSITIVOS'), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-host-estudio')), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-host-vps-hetzner')), findsOneWidget);
    // portatil is offline: its daemon can not be asked.
    expect(find.byKey(const ValueKey('devices-host-portatil')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('devices-host-estudio')));
    expect(find.text('Dispositivos'), findsOneWidget);
    expect(find.text('Pixel de Ana'), findsOneWidget);
  });

  testWidgets('SSH host: every device, with scope, guest, sessions and presence; revoke asks first', (tester) async {
    final f = await pumpUi(tester, const DevicesScreen(hostId: 'estudio'), height: 1600);
    await settle(tester);
    expect(find.text('Pixel de Ana'), findsOneWidget);
    expect(find.text('MacBook'), findsOneWidget);
    expect(find.text('iPad de visita'), findsOneWidget);
    expect(find.text('este dispositivo'), findsNothing);
    expect(find.textContaining('macOS · conectado'), findsOneWidget);
    expect(find.textContaining('Android · visto hace 3 h'), findsOneWidget);
    expect(find.textContaining('iOS · sin conexiones · caduca'), findsOneWidget);
    expect(find.text('invitado'), findsOneWidget);
    expect(find.text('claude@docs'), findsOneWidget);
    expect(find.text('solo ver'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('device-revoke-dpixel0000001')));
    expect(find.text('¿Revocar Pixel de Ana?'), findsOneWidget);
    expect(find.textContaining('necesita una invitación nueva'), findsOneWidget);
    await _tap(tester, find.text('Cancelar'));
    expect(f.devices.calls, isEmpty);
    expect(find.text('Pixel de Ana'), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('device-revoke-dpixel0000001')));
    await _tap(tester, find.byKey(const ValueKey('device-revoke-confirm')));
    expect((f.devices.calls.single.session, f.devices.calls.single.arg), ('estudio', 'dpixel0000001'));
    expect(find.byKey(const ValueKey('device-dpixel0000001')), findsNothing);
    expect(find.text('Pixel de Ana revocado'), findsOneWidget);
    expect(find.text('MacBook'), findsOneWidget);
  });

  testWidgets('relay owner admin: all devices, this one marked; revoking it warns and removes the host', (tester) async {
    final f = await _relayFakes('estudio', RelayScope.admin);
    await pumpUi(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DevicesScreen(hostId: 'estudio'))),
          child: const Text('open'),
        ),
      ),
      fakes: f,
      height: 1600,
    );
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.text('este dispositivo'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-revoke-dmacbook00001')), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('device-revoke-dme')));
    expect(find.text('¿Revocar este dispositivo?'), findsOneWidget);
    expect(find.textContaining('el host se quitará de la app'), findsOneWidget);
    expect(find.textContaining('emparejarlo de nuevo'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('device-revoke-confirm')));
    await settle(tester);
    expect(f.devices.calls.single.arg, 'dme');
    expect(f.hosts.hosts.any((h) => h.config.id == 'estudio'), isFalse);
    // Back where the user came from.
    expect(find.text('Dispositivos'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('any other relay device sees and revokes only itself', (tester) async {
    final f = await _relayFakes('estudio', RelayScope.operate);
    await pumpUi(tester, const DevicesScreen(hostId: 'estudio'), fakes: f, height: 1600);
    await settle(tester);
    expect(find.byKey(const ValueKey('device-dme')), findsOneWidget);
    expect(find.text('Pixel de Ana'), findsNothing);
    expect(find.textContaining('solo ve su propio acceso'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-revoke-dme')), findsOneWidget);
  });

  testWidgets('failures: the list offers a retry, a refused revoke keeps the device', (tester) async {
    final f = Fakes();
    f.devices.listError = const DevicesException(DevicesFailure.forbidden);
    await pumpUi(tester, const DevicesScreen(hostId: 'estudio'), fakes: f, height: 1600);
    await settle(tester);
    expect(find.byKey(const ValueKey('devices-error')), findsOneWidget);
    expect(find.textContaining('no deja ver sus dispositivos'), findsOneWidget);
    f.devices.listError = null;
    await _tap(tester, find.text('Reintentar'));
    expect(find.text('MacBook'), findsOneWidget);

    f.devices.revokeError = const DevicesException(DevicesFailure.unavailable);
    await _tap(tester, find.byKey(const ValueKey('device-revoke-dmacbook00001')));
    await _tap(tester, find.byKey(const ValueKey('device-revoke-confirm')));
    expect(find.text('No se pudo revocar: sin conexión con el host'), findsOneWidget);
    expect(find.text('MacBook'), findsOneWidget);
  });

  test('error texts', () {
    for (final v in DevicesFailure.values) {
      expect(devicesErrorText(DevicesException(v)), isNotEmpty);
      expect(devicesErrorText(DevicesException(v), revoking: true), isNotEmpty);
    }
    expect(devicesErrorText(StateError('x')), contains('sin conexión'));
  });
}
