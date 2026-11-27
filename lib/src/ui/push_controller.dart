// Push notifications on the app side: registers this device's FCM token on
// every agentd host it connects to (op push_register, `host_ref` = the saved
// host id), again when the token changes, and removes it when the user turns
// push off or removes the host. Taps come out of [opens]; a push received in
// the foreground only reconnects the hosts (the Panel is live).

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/contracts.dart';
import '../platform/push.dart';

class PushController {
  PushController({required this.hosts, required this.push, required this.messaging, required this.enabled, this.deviceName = 'Android'});

  final HostsRepository hosts;
  final PushRepository push;
  final PushMessaging messaging;

  /// The "Notificaciones push" setting (read on every decision).
  final bool Function() enabled;
  final String deviceName;

  final _subs = <StreamSubscription<Object?>>[];
  final _opens = StreamController<PushOpen>.broadcast();
  List<HostStatus> _hosts = const [];
  bool _ready = false;
  bool _asked = false;
  String? _token;

  /// Hosts the current token is registered on in this connection (cleared
  /// when the host goes offline, so a reconnect registers again).
  final _registered = <String>{};
  final _inFlight = <String>{};

  /// Hosts whose daemon pushes to this device: registered with the current
  /// token at some point, kept while the host is offline (it still pushes).
  final _pushing = <String>{};

  /// Hosts that reach this device by push while the app holds no connection
  /// to them (the background controller closes those connections).
  Set<String> get pushHosts => _ready && enabled() && _token != null ? Set.unmodifiable(_pushing) : const {};

  /// Tapped notifications (cold start first).
  Stream<PushOpen> get opens => _opens.stream;

  bool get available => _ready;

  Future<void> start() async {
    _ready = await messaging.init();
    if (!_ready) return;
    _subs
      ..add(hosts.watch().listen((h) {
        _hosts = h;
        unawaited(_sync());
      }))
      ..add(messaging.tokenRefresh.listen((t) => unawaited(_newToken(t))))
      ..add(messaging.opens.listen(_opens.add))
      ..add(messaging.foreground.listen((_) => unawaited(hosts.reconnectAll())));
    final first = await messaging.initialOpen();
    if (first != null) _opens.add(first);
    _token = await messaging.token();
    await _sync();
  }

  static bool _reachable(HostStatus h) => h.state == HostState.online && (h.capabilities?.has('agentd') ?? false);

  Future<void> _sync() async {
    final online = {for (final h in _hosts) if (_reachable(h)) h.config.id};
    _registered.retainAll(online);
    final token = _token;
    if (!_ready || token == null || !enabled()) return;
    if (!_asked) {
      _asked = true;
      await messaging.requestPermission();
    }
    for (final id in online) {
      if (_registered.contains(id) || !_inFlight.add(id)) continue;
      try {
        if (await push.register(id, token: token, deviceName: deviceName) && _token == token && enabled()) {
          _registered.add(id);
          _pushing.add(id);
        }
      } finally {
        _inFlight.remove(id);
      }
    }
  }

  Future<void> _newToken(String t) async {
    final old = _token;
    _token = t;
    final was = Set.of(_registered);
    _registered.clear();
    _pushing.clear();
    if (old != null && old != t) {
      for (final id in was) {
        await push.unregister(id, token: old);
      }
    }
    await _sync();
  }

  /// Re-evaluates after the setting changed: off unregisters every host.
  Future<void> settingsChanged() async {
    if (!_ready) return;
    final token = _token;
    if (enabled()) return _sync();
    final was = Set.of(_registered);
    _registered.clear();
    _pushing.clear();
    if (token == null) return;
    for (final id in was) {
      await push.unregister(id, token: token);
    }
  }

  /// Before [hostId] is removed from the app: its daemon stops pushing here.
  Future<void> forget(String hostId) async {
    final token = _token;
    final was = _registered.remove(hostId);
    _pushing.remove(hostId);
    if (token != null && was) await push.unregister(hostId, token: token);
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _opens.close();
  }
}

/// Gives screens the app's [PushController] (removing a host unregisters
/// it first). Absent in screen tests.
class PushScope extends InheritedWidget {
  const PushScope({super.key, required this.controller, required super.child});
  final PushController controller;

  static PushController? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<PushScope>()?.controller;

  @override
  bool updateShouldNotify(PushScope oldWidget) => controller != oldWidget.controller;
}
