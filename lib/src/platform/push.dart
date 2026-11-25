// Firebase Cloud Messaging behind a small interface: the device token, its
// refreshes, and the notifications the user taps. The daemons send the
// pushes themselves (agentd `[push]`); the app only registers its token on
// each host and routes the taps. Without a Firebase config in the build
// (android/app/google-services.json, gitignored) [FirebasePushMessaging.init]
// answers false and the app runs without push. Elsewhere (tests, fakes)
// [NoopPushMessaging] does nothing.
//
// Never log the token: it addresses this device.

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../core/contracts.dart';

abstract class PushMessaging {
  /// Starts the messaging client; false when push is not available in this
  /// build (no Firebase config) or on this device (no Play services).
  Future<bool> init();

  /// Asks for the notification permission (Android 13+, iOS).
  Future<void> requestPermission();

  /// The current FCM token (null when there is none yet).
  Future<String?> token();

  /// A new token replaced the previous one.
  Stream<String> get tokenRefresh;

  /// A push arrived while the app was in the foreground (no system
  /// notification is shown then).
  Stream<PushOpen> get foreground;

  /// A notification was tapped while the app was in the background.
  Stream<PushOpen> get opens;

  /// The notification that started the app, if any (cold start).
  Future<PushOpen?> initialOpen();
}

class NoopPushMessaging implements PushMessaging {
  const NoopPushMessaging();
  @override
  Future<bool> init() async => false;
  @override
  Future<void> requestPermission() async {}
  @override
  Future<String?> token() async => null;
  @override
  Stream<String> get tokenRefresh => const Stream.empty();
  @override
  Stream<PushOpen> get foreground => const Stream.empty();
  @override
  Stream<PushOpen> get opens => const Stream.empty();
  @override
  Future<PushOpen?> initialOpen() async => null;
}

class FirebasePushMessaging implements PushMessaging {
  bool _ready = false;

  FirebaseMessaging get _m => FirebaseMessaging.instance;

  static PushOpen? _open(RemoteMessage m) => PushOpen.fromData(m.data);

  @override
  Future<bool> init() async {
    if (_ready) return true;
    try {
      // Reads the options from google-services.json (Android) or
      // GoogleService-Info.plist (iOS); throws when the build has none.
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      // The daemons' pushes are notification messages: in the foreground
      // they are not shown (the Panel is live then).
      await _m.setForegroundNotificationPresentationOptions(alert: false, badge: false, sound: false);
      _ready = true;
    } catch (_) {
      _ready = false;
    }
    return _ready;
  }

  @override
  Future<void> requestPermission() async {
    if (!_ready) return;
    try {
      await _m.requestPermission();
    } catch (_) {}
  }

  @override
  Future<String?> token() async {
    if (!_ready) return null;
    try {
      // The classic registration token: what FCM HTTP v1 `message.token`
      // takes (the daemon's contract). register()/onRegistered give an
      // installation id instead, not used by agentd yet.
      // ignore: deprecated_member_use
      return await _m.getToken();
    } catch (_) {
      return null;
    }
  }

  @override
  // ignore: deprecated_member_use
  Stream<String> get tokenRefresh => _ready ? _m.onTokenRefresh : const Stream.empty();

  @override
  Stream<PushOpen> get foreground => _ready ? FirebaseMessaging.onMessage.map(_open).where((o) => o != null).cast<PushOpen>() : const Stream.empty();

  @override
  Stream<PushOpen> get opens => _ready ? FirebaseMessaging.onMessageOpenedApp.map(_open).where((o) => o != null).cast<PushOpen>() : const Stream.empty();

  @override
  Future<PushOpen?> initialOpen() async {
    if (!_ready) return null;
    try {
      final m = await _m.getInitialMessage();
      return m == null ? null : _open(m);
    } catch (_) {
      return null;
    }
  }
}
