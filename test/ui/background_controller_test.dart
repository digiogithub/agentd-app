import 'dart:async';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/platform/background.dart';
import 'package:agentd_app/src/ui/background_controller.dart';
import 'package:agentd_app/src/ui/fakes/fake_repositories.dart';
import 'package:agentd_app/src/ui/providers.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements BackgroundBridge {
  final calls = <String>[];
  final notes = <(int, String, String, String?)>[];
  final _disc = StreamController<void>.broadcast();
  bool allowStart = true;

  @override
  Stream<void> get disconnects => _disc.stream;
  @override
  Stream<String> get opens => const Stream.empty();
  void tapDisconnect() => _disc.add(null);

  @override
  Future<bool> startService({required String title, required String text}) async {
    calls.add('start:$text');
    return allowStart;
  }

  @override
  Future<void> stopService() async => calls.add('stop');

  @override
  Future<void> notify({required int id, required String title, required String text, String? session}) async =>
      notes.add((id, title, text, session));

  @override
  Future<bool> requestPermission() async {
    calls.add('permission');
    return true;
  }

  @override
  Future<VoiceStart> startVoice() async => VoiceStart.ok;
}

class _Sessions implements SessionsRepository {
  final c = StreamController<List<AgentSession>>.broadcast();
  @override
  Stream<List<AgentSession>> watch() => c.stream;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

HostStatus _host(String id, HostState st) =>
    HostStatus(HostConfig(id: id, name: id, host: '$id.local', user: 'u'), state: st);

AgentSession _s(String name, AgentStatus st, {String? preview}) =>
    AgentSession(hostId: 'h', source: SessionSource.agentd, name: name, status: st, preview: preview);

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeHostsRepository hosts;
  late _Sessions sessions;
  late _Bridge bridge;
  late AppSettings settings;
  late DateTime now;
  late BackgroundController c;

  setUp(() {
    hosts = FakeHostsRepository(hosts: [_host('estudio', HostState.online), _host('vps', HostState.offline)]);
    sessions = _Sessions();
    bridge = _Bridge();
    settings = const AppSettings(muted: [MutedSession('claude@ruido', 'hasta mañana')]);
    now = DateTime(2026, 11, 18, 12);
    c = BackgroundController(hosts: hosts, sessions: sessions, bridge: bridge, settings: () => settings, now: () => now)..start();
  });

  tearDown(() => c.dispose());

  test('the service runs while a host is online and follows the list', () async {
    await _tick();
    expect(bridge.calls, ['permission', startsWith('start:estudio ·')]);
    await hosts.connect('vps');
    await _tick();
    expect(bridge.calls.last, startsWith('start:estudio, vps ·'));
    await hosts.disconnectAll();
    await _tick();
    expect(bridge.calls.last, 'stop');
  });

  test('Desconectar in the notification disconnects every host', () async {
    await _tick();
    bridge.tapDisconnect();
    await _tick();
    expect(hosts.disconnected, ['estudio', 'vps']);
    expect(bridge.calls.last, 'stop');
  });

  test('turning the setting off stops the service', () async {
    await _tick();
    settings = settings.copyWith(keepConnected: false);
    c.settingsChanged();
    await _tick();
    expect(bridge.calls.last, 'stop');
  });

  test('back in the foreground every host is tried again', () async {
    c.setForeground(false);
    c.setForeground(true);
    await _tick();
    expect(hosts.reconnects, 1);
    c.setForeground(true);
    expect(hosts.reconnects, 1, reason: 'only on the transition');
  });

  test('event notifications only in the background, by setting, muted and debounced', () async {
    sessions.c.add([_s('claude@a', AgentStatus.working), _s('claude@ruido', AgentStatus.working)]);
    await _tick();
    // Foreground: nothing.
    sessions.c.add([_s('claude@a', AgentStatus.idle), _s('claude@ruido', AgentStatus.working)]);
    await _tick();
    expect(bridge.notes, isEmpty);

    c.setForeground(false);
    sessions.c.add([_s('claude@a', AgentStatus.working), _s('claude@ruido', AgentStatus.working)]);
    sessions.c.add([_s('claude@a', AgentStatus.idle, preview: 'Hecho'), _s('claude@ruido', AgentStatus.idle)]);
    await _tick();
    expect(bridge.notes.map((n) => (n.$2, n.$3, n.$4)), [('claude@a terminó el turno', 'Hecho', 'h/agentd/claude@a')]);

    // Same kind again within 30 s: grouped.
    sessions.c.add([_s('claude@a', AgentStatus.working)]);
    sessions.c.add([_s('claude@a', AgentStatus.idle)]);
    await _tick();
    expect(bridge.notes, hasLength(1));

    // Waiting is another kind; exit is off by default.
    sessions.c.add([_s('claude@a', AgentStatus.waiting, preview: '¿Migro?')]);
    sessions.c.add([_s('claude@a', AgentStatus.exited)]);
    await _tick();
    expect(bridge.notes.map((n) => n.$2), ['claude@a terminó el turno', 'claude@a espera respuesta']);

    now = now.add(const Duration(seconds: 31));
    sessions.c.add([_s('claude@a', AgentStatus.working)]);
    sessions.c.add([_s('claude@a', AgentStatus.idle)]);
    await _tick();
    expect(bridge.notes, hasLength(3));
  });

  test('the battery saver level sets the time before the suspend', () {
    expect(c.suspendAfter, const Duration(minutes: 1));
    settings = settings.copyWith(batterySaver: BatterySaver.high);
    expect(c.suspendAfter, PowerTuning.high.suspendAfter);
  });

  test('hosts that push are disconnected after a while in the background', () async {
    await c.dispose();
    hosts = FakeHostsRepository(hosts: [_host('estudio', HostState.online), _host('vps', HostState.online), _host('casa', HostState.connecting)]);
    var push = {'estudio', 'casa'};
    c = BackgroundController(
      hosts: hosts,
      sessions: sessions,
      bridge: bridge,
      settings: () => settings,
      pushHosts: () => push,
      suspendAfter: const Duration(milliseconds: 30),
      now: () => now,
    )..start();
    await _tick();

    // A quick trip to another app keeps the connections.
    c.setForeground(false);
    c.setForeground(true);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(hosts.disconnected, isEmpty);

    c.setForeground(false);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(hosts.disconnected, unorderedEquals(['estudio', 'casa']), reason: 'vps has no push: it keeps its connection');

    // Without push nothing is closed.
    push = {};
    c.setForeground(true);
    hosts.disconnected.clear();
    c.setForeground(false);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(hosts.disconnected, isEmpty);
  });
}
