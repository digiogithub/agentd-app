// PushController: registers the token on every online agentd host, again on
// reconnect and token refresh, unregisters when push is turned off or a host
// is removed, and passes taps on. PushOpen reads the daemon's push data.

import 'dart:async';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/platform/push.dart';
import 'package:agentd_app/src/ui/fakes/fake_repositories.dart';
import 'package:agentd_app/src/ui/providers.dart';
import 'package:agentd_app/src/ui/push_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../data/fakes.dart';

class _Messaging implements PushMessaging {
  _Messaging({this.ready = true, this.initial});
  final bool ready;
  final PushOpen? initial;
  String? current = 'tok1';
  int permissionAsks = 0;
  final refresh = StreamController<String>.broadcast();
  final fg = StreamController<PushOpen>.broadcast();
  final taps = StreamController<PushOpen>.broadcast();

  @override
  Future<bool> init() async => ready;
  @override
  Future<void> requestPermission() async => permissionAsks++;
  @override
  Future<String?> token() async => current;
  @override
  Stream<String> get tokenRefresh => refresh.stream;
  @override
  Stream<PushOpen> get foreground => fg.stream;
  @override
  Stream<PushOpen> get opens => taps.stream;
  @override
  Future<PushOpen?> initialOpen() async => initial;
}

class _Hosts extends StubHosts {
  _Hosts(List<HostStatus> list) : super(list, const {});
  int reconnects = 0;
  @override
  Future<void> reconnectAll() async => reconnects++;
}

HostStatus _offline(String id) => HostStatus(HostConfig(id: id, name: id, host: '$id.local', user: 'u'), state: HostState.offline);

void main() {
  late _Hosts hosts;
  late FakePushRepository repo;
  late _Messaging m;
  late PushController c;
  var enabled = true;

  Future<void> start({_Messaging? messaging}) async {
    m = messaging ?? _Messaging();
    c = PushController(hosts: hosts, push: repo, messaging: m, enabled: () => enabled, deviceName: 'Pixel');
    addTearDown(c.dispose);
    await c.start();
  }

  setUp(() {
    enabled = true;
    repo = FakePushRepository();
    hosts = _Hosts([onlineHost('a', testCaps()), onlineHost('b', testCaps()), onlineHost('plain', testCaps(agentd: false)), _offline('c')]);
  });

  test('registers on every online agentd host once, asks for permission once', () async {
    await start();
    await eventually(() => repo.registered.length == 2);
    expect(repo.registered, {'a': 'tok1', 'b': 'tok1'});
    expect(m.permissionAsks, 1);
    hosts.set([onlineHost('a', testCaps()), onlineHost('b', testCaps()), onlineHost('c', testCaps())]);
    await eventually(() => repo.registered.containsKey('c'));
    expect(repo.calls.where((x) => x == 'register a').length, 1);
    expect(m.permissionAsks, 1);
  });

  test('a host that went offline is registered again when it is back', () async {
    await start();
    await eventually(() => repo.registered.length == 2);
    hosts.set([_offline('a'), onlineHost('b', testCaps())]);
    await pumpEventQueue();
    hosts.set([onlineHost('a', testCaps()), onlineHost('b', testCaps())]);
    await eventually(() => repo.calls.where((x) => x == 'register a').length == 2);
  });

  test('pushHosts: registered hosts, kept offline, cleared when push is off or the host forgotten', () async {
    repo.refusing.add('b');
    await start();
    await eventually(() => repo.registered.containsKey('a'));
    expect(c.pushHosts, {'a'});
    hosts.set([_offline('a'), onlineHost('b', testCaps())]);
    await pumpEventQueue();
    expect(c.pushHosts, {'a'}, reason: 'its daemon still pushes while the app is disconnected');
    enabled = false;
    expect(c.pushHosts, isEmpty);
    enabled = true;
    await c.forget('a');
    expect(c.pushHosts, isEmpty);
  });

  test('a refusing host (older daemon) is tried again on the next update', () async {
    repo.refusing.add('a');
    await start();
    await eventually(() => repo.registered.containsKey('b'));
    expect(repo.registered.containsKey('a'), isFalse);
    repo.refusing.clear();
    hosts.set([onlineHost('a', testCaps()), onlineHost('b', testCaps())]);
    await eventually(() => repo.registered.containsKey('a'));
  });

  test('a new token replaces the old one on every host', () async {
    await start();
    await eventually(() => repo.registered.length == 2);
    m.refresh.add('tok2');
    await eventually(() => repo.registered.values.every((t) => t == 'tok2') && repo.registered.length == 2);
    expect(repo.calls.where((x) => x.startsWith('unregister')).length, 2);
  });

  test('turning push off unregisters; on registers again', () async {
    await start();
    await eventually(() => repo.registered.length == 2);
    enabled = false;
    await c.settingsChanged();
    expect(repo.registered, isEmpty);
    hosts.set([onlineHost('a', testCaps())]);
    await pumpEventQueue();
    expect(repo.registered, isEmpty);
    enabled = true;
    await c.settingsChanged();
    expect(repo.registered, {'a': 'tok1'});
  });

  test('off from the start registers nothing and does not ask for permission', () async {
    enabled = false;
    await start();
    await pumpEventQueue();
    expect(repo.calls, isEmpty);
    expect(m.permissionAsks, 0);
  });

  test('forget unregisters a host before it is removed', () async {
    await start();
    await eventually(() => repo.registered.length == 2);
    await c.forget('a');
    expect(repo.registered, {'b': 'tok1'});
    await c.forget('nope');
  });

  test('without a Firebase config nothing happens', () async {
    await start(messaging: _Messaging(ready: false));
    await pumpEventQueue();
    expect(c.available, isFalse);
    expect(repo.calls, isEmpty);
    await c.settingsChanged();
    await c.forget('a');
  });

  test('taps come out of opens (cold start first); a foreground push reconnects', () async {
    const cold = PushOpen(hostId: 'a', session: 'claude@x', reason: 'question', messageId: 5);
    const warm = PushOpen(hostId: 'b', session: 'claude@y', reason: 'permission');
    m = _Messaging(initial: cold);
    c = PushController(hosts: hosts, push: repo, messaging: m, enabled: () => enabled);
    addTearDown(c.dispose);
    final got = <PushOpen>[];
    c.opens.listen(got.add);
    await c.start();
    m.taps.add(warm);
    m.fg.add(warm);
    await pumpEventQueue();
    expect(got, [cold, warm]);
    expect(hosts.reconnects, 1);
  });

  test('PushOpen reads the daemon data and refuses anything else', () {
    final o = PushOpen.fromData({'v': '1', 'host': 'estudio', 'host_ref': 'h1', 'session': 'claude@x', 'reason': 'question', 'message_id': '42', 'link': 'agentd://open?h=h1&s=claude@x'});
    expect(o, const PushOpen(hostId: 'h1', session: 'claude@x', reason: 'question', messageId: 42));
    expect(o!.sessionKey, 'h1/agentd/claude@x');
    expect(PushOpen.fromData({'v': '1', 'host_ref': 'h1', 'session': 's', 'reason': 'permission'})!.messageId, isNull);
    expect(PushOpen.fromData({'v': '2', 'host_ref': 'h1', 'session': 's'}), isNull);
    expect(PushOpen.fromData({'v': '1', 'session': 's'}), isNull);
    expect(PushOpen.fromData({'v': '1', 'host_ref': '', 'session': 's'}), isNull);
    expect(PushOpen.fromData(const {}), isNull);
  });

  test('the setting is on by default and stored', () {
    expect(const AppSettings().pushEnabled, isTrue);
    final off = const AppSettings(muted: []).copyWith(pushEnabled: false);
    expect(appSettingsFromJson(off.toJson()).pushEnabled, isFalse);
    expect(appSettingsFromJson(<String, Object?>{}).pushEnabled, isTrue);
  });
}
