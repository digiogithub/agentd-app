// The Dart side of the Android Auto client. Android runs it in its own
// headless Flutter engine (`CarEngine.kt`, entry point `carMain` of
// `main.dart`), so the car
// works while the phone is locked and the app closed: that engine has its own
// repositories and connections, separate from the app's. The hands-free voice
// mode (`voice/voice_bridge.dart`, channel `agentd/voice`) runs on the same
// engine and hub.
//
// Channel `agentd/car`:
//  Dart -> Android: `ready`, `snapshot` (map), `notify` (CarNotice map),
//    `cancel` (tag).
//  Android -> Dart: `snapshot`, `refresh`, `answer {hostId, questionId,
//    text}`, `choose {key, optionId}`, `prompt {key, text}`, `reply {key,
//    text}` (-> what happened, Spanish), `conclusion {key}` (-> text),
//    `lastLines {key, n}` (-> list of lines).
// A refused action is a PlatformException with code `refused` and a Spanish
// message for the driver.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/data.dart';
import '../ui/providers.dart' show PrefsSettingsStore;
import '../ui/screens/chat_tab.dart' show sendErrorMessage;
import '../voice/voice_bridge.dart';
import 'car_hub.dart';

/// Body of the car engine's entry point (`carMain` in `main.dart`, started by
/// `CarEngine.kt`).
Future<void> runCarEngine() async {
  WidgetsFlutterBinding.ensureInitialized();
  final data = AppData.create();
  final hub = CarHub(hosts: data.hosts, sessions: data.sessions, board: data.board);
  // The voice mode shares the hub; its handler must exist before `ready`
  // releases the calls queued natively. Settings are read from the app's
  // store at each start (the app writes them in its own engine).
  VoiceBridge(hub, headsetMic: () async => (await PrefsSettingsStore().load()).voiceHeadsetMic).start();
  CarBridge(hub).start();
}

class CarBridge {
  CarBridge(this.hub, [MethodChannel? channel]) : _ch = channel ?? const MethodChannel('agentd/car');

  final CarHub hub;
  final MethodChannel _ch;

  void start() {
    _ch.setMethodCallHandler(handle);
    hub.snapshots.listen((s) => _send('snapshot', s));
    hub.notices.listen((n) => _send('notify', n.toMap()));
    hub.cancels.listen((t) => _send('cancel', t));
    hub.start();
    _send('ready', null);
  }

  void _send(String method, Object? args) => unawaited(_ch.invokeMethod<void>(method, args).catchError((Object _) {}));

  /// One call from Android.
  Future<Object?> handle(MethodCall call) async {
    final a = call.arguments is Map ? Map<String, Object?>.from(call.arguments as Map) : const <String, Object?>{};
    String str(String k) => a[k] is String ? a[k] as String : throw PlatformException(code: 'bad_args', message: 'Falta $k');
    try {
      switch (call.method) {
        case 'snapshot':
          return hub.snapshot;
        case 'refresh':
          unawaited(hub.refresh().catchError((Object _) {}));
          return null;
        case 'answer':
          final id = a['questionId'];
          if (id is! int) throw PlatformException(code: 'bad_args', message: 'Falta questionId');
          await hub.answer(str('hostId'), id, str('text'));
          return null;
        case 'choose':
          await hub.choose(str('key'), str('optionId'));
          return null;
        case 'prompt':
          await hub.prompt(str('key'), str('text'));
          return null;
        case 'reply':
          return await hub.reply(str('key'), str('text'));
        case 'conclusion':
          return await hub.conclusion(str('key'));
        case 'lastLines':
          final n = a['n'] is int ? a['n'] as int : 8;
          return await hub.lastLines(str('key'), n.clamp(1, 40));
      }
      throw MissingPluginException(call.method);
    } on CarActionException catch (e) {
      throw PlatformException(code: 'refused', message: e.message);
    } on PlatformException {
      rethrow;
    } on MissingPluginException {
      rethrow;
    } catch (e) {
      // Daemon refusals (busy, exited, forbidden...) in the chat's words.
      throw PlatformException(code: 'refused', message: sendErrorMessage(e));
    }
  }
}
