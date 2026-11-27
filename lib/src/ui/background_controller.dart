// Background behaviour of the app: reconnect when it comes back to the
// foreground, keep a "connected" notification (Android foreground service)
// while a host is online, disconnect from it, and notify agent events while
// the app is not in the foreground.
//
// Battery: a host whose daemon pushes to this device (questions,
// permissions) needs no connection in the background. [suspendAfter] in the
// background its connection is closed (no relay pings, event streams, views
// or polls) and the service stops when no host is left; back in the
// foreground every host is connected again.

import 'dart:async';

import '../core/contracts.dart';
import '../platform/background.dart';
import 'providers.dart';

class BackgroundController {
  BackgroundController({
    required this.hosts,
    required this.sessions,
    required this.bridge,
    required this.settings,
    Set<String> Function()? pushHosts,
    this._suspendAfter,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _pushHosts = pushHosts ?? (() => const {});

  final HostsRepository hosts;
  final SessionsRepository sessions;
  final BackgroundBridge bridge;

  /// Current settings (read on every decision).
  final AppSettings Function() settings;

  /// Hosts that push to this device (PushController.pushHosts).
  final Set<String> Function() _pushHosts;

  /// Time in the background before the connections of [_pushHosts] close
  /// (a quick switch to another app keeps them): a fixed value (tests) or
  /// the battery saver level's.
  Duration get suspendAfter => _suspendAfter ?? PowerTuning.of(settings().batterySaver).suspendAfter;
  final Duration? _suspendAfter;
  Timer? _suspend;

  final _subs = <StreamSubscription<Object?>>[];
  final _last = <String, AgentStatus>{};
  final _sent = <String, DateTime>{}; // "key|kind" → last notification
  final DateTime Function() _now;

  /// At most one notification of a kind per session in this window
  /// ("Agrupado cada 30 s por sesión").
  static const debounce = Duration(seconds: 30);
  List<HostStatus> _hosts = const [];
  bool _foreground = true;
  bool _asked = false;
  (String, String)? _shown; // the notification text shown, null = no service

  /// Session keys of tapped event notifications (the UI opens them).
  Stream<String> get opens => bridge.opens;

  void start() {
    _subs
      ..add(
        hosts.watch().listen((h) {
          _hosts = h;
          unawaited(_sync());
        }),
      )
      ..add(sessions.watch().listen(_sessions))
      ..add(bridge.disconnects.listen((_) => unawaited(hosts.disconnectAll())));
  }

  /// The app lifecycle: back in the foreground every saved host is tried
  /// again (dead connections are reopened at once).
  void setForeground(bool fg) {
    final was = _foreground;
    _foreground = fg;
    _suspend?.cancel();
    _suspend = null;
    if (fg && !was) unawaited(hosts.reconnectAll());
    if (!fg && was) _suspend = Timer(suspendAfter, _suspendPushHosts);
  }

  /// Closes the connection (or the reconnect attempts) of every host that
  /// pushes to this device.
  void _suspendPushHosts() {
    _suspend = null;
    if (_foreground) return;
    final push = _pushHosts();
    for (final h in _hosts) {
      if (h.state != HostState.offline && push.contains(h.config.id)) unawaited(hosts.disconnect(h.config.id));
    }
  }

  bool get foreground => _foreground;

  /// Re-evaluates the service after a settings change.
  void settingsChanged() => unawaited(_sync());

  Future<void> _sync() async {
    final online = [for (final h in _hosts) if (h.state == HostState.online) h.config.name];
    final want = settings().keepConnected && online.isNotEmpty ? ('agentd · conectado', _describe(online)) : null;
    if (want == _shown) return;
    if (want == null) {
      _shown = null;
      await bridge.stopService();
      return;
    }
    if (!_asked) {
      _asked = true;
      await bridge.requestPermission();
    }
    if (await bridge.startService(title: want.$1, text: want.$2)) _shown = want;
  }

  static String _describe(List<String> online) {
    final hosts = online.length <= 3 ? online.join(', ') : '${online.take(2).join(', ')} y ${online.length - 2} más';
    return '$hosts · toca Desconectar para cerrar la conexión';
  }

  void _sessions(List<AgentSession> list) {
    final s = settings();
    final seen = <String>{};
    for (final x in list) {
      seen.add(x.key);
      final prev = _last[x.key];
      _last[x.key] = x.status;
      if (prev == null || prev == x.status || _foreground) continue;
      if (s.muted.any((m) => m.session == x.name)) continue;
      final (title, text) = switch (x.status) {
        AgentStatus.waiting when s.notifyWaiting => ('${x.name} espera respuesta', x.pending?.question ?? x.preview ?? ''),
        AgentStatus.idle when prev == AgentStatus.working && s.notifyTurnDone => ('${x.name} terminó el turno', x.preview ?? ''),
        AgentStatus.exited when s.notifyExit => ('${x.name} se cerró', x.preview ?? ''),
        _ => ('', ''),
      };
      if (title.isEmpty) continue;
      final kind = '${x.key}|${x.status.name}';
      final at = _sent[kind];
      if (at != null && _now().difference(at) < debounce) continue;
      _sent[kind] = _now();
      unawaited(bridge.notify(id: notificationId(x.key), title: title, text: text, session: x.key));
    }
    _last.removeWhere((k, _) => !seen.contains(k));
  }

  /// Stable id of a session's notification (1 is the service's).
  static int notificationId(String key) => 100 + (key.hashCode & 0x3fffffff);

  Future<void> dispose() async {
    _suspend?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    if (_shown != null) await bridge.stopService();
  }
}
