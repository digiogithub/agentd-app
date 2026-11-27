// Bridge to the Android side of the background connection (MainActivity +
// ConnectionService, channel `agentd/background`): the foreground-service
// notification that keeps the SSH connections open, and the agents' event
// notifications. Elsewhere (iOS, tests) [NoopBackgroundBridge] does nothing.

import 'dart:async';

import 'package:flutter/services.dart';

abstract class BackgroundBridge {
  /// Shows (or updates) the persistent "connected" notification and keeps the
  /// app process alive. False when the system refused (Android 12+ does not
  /// start one from the background).
  Future<bool> startService({required String title, required String text});

  /// Removes it; the process may then be suspended in the background.
  Future<void> stopService();

  /// An event notification; tapping it reports [session] on [opens].
  Future<void> notify({required int id, required String title, required String text, String? session});

  /// Asks for the notification permission (Android 13+); true when granted
  /// already (the system dialog answers later).
  Future<bool> requestPermission();

  /// The notification's "Desconectar" action.
  Stream<void> get disconnects;

  /// An event notification was tapped: the session key it was about.
  Stream<String> get opens;
}

class MethodChannelBackgroundBridge implements BackgroundBridge {
  MethodChannelBackgroundBridge([MethodChannel? channel]) : _ch = channel ?? const MethodChannel('agentd/background') {
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'disconnect':
          _disconnects.add(null);
        case 'open':
          if (call.arguments is String) _opens.add(call.arguments as String);
      }
      return null;
    });
  }

  final MethodChannel _ch;
  final _disconnects = StreamController<void>.broadcast();
  final _opens = StreamController<String>.broadcast();

  @override
  Stream<void> get disconnects => _disconnects.stream;

  @override
  Stream<String> get opens => _opens.stream;

  @override
  Future<bool> startService({required String title, required String text}) async {
    try {
      return await _ch.invokeMethod<bool>('startService', {'title': title, 'text': text}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> stopService() async {
    try {
      await _ch.invokeMethod<void>('stopService');
    } on PlatformException {
      // nothing to stop
    }
  }

  @override
  Future<void> notify({required int id, required String title, required String text, String? session}) async {
    try {
      await _ch.invokeMethod<void>('notify', {'id': id, 'title': title, 'text': text, 'session': session});
    } on PlatformException {
      // notifications denied or unavailable: the in-app state still shows it
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      return await _ch.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    }
  }
}

/// No background support (iOS, desktop, tests): every call is a no-op.
class NoopBackgroundBridge implements BackgroundBridge {
  @override
  Stream<void> get disconnects => const Stream.empty();
  @override
  Stream<String> get opens => const Stream.empty();
  @override
  Future<bool> startService({required String title, required String text}) async => false;
  @override
  Future<void> stopService() async {}
  @override
  Future<void> notify({required int id, required String title, required String text, String? session}) async {}
  @override
  Future<bool> requestPermission() async => false;
}

/// The installed version, "1.11.7" (Android; empty elsewhere or on
/// failure).
Future<String> appVersion() async {
  try {
    return await const MethodChannel('agentd/background').invokeMethod<String>('appVersion') ?? '';
  } catch (_) {
    return '';
  }
}
