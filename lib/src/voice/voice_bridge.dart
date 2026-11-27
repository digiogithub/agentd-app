// The Dart side of the hands-free voice mode on the headless car engine
// (`runCarEngine`): [MethodChannelVoicePort] speaks the native
// `agentd/voice` channel, and [VoiceBridge] owns the lifecycle of the
// [VoiceController] that the native VoiceService starts and stops.
//
// Channel `agentd/voice`:
//  Dart -> Android: `say {text}` (null when the speech ends or is cut; error
//    `tts`), `listen {maxMs, headsetMic}` (-> {alts: [...]} or {error:
//    code}), `earcon {kind}`, `stopSpeaking`, `exit`, `state {text}` (the
//    voice notification's text).
//  Android -> Dart: `button {key}`, `started {source}` (sent again when the
//    mode is started while running), `stopped {}`, `route {bt}`.
// Never log what is said or heard.

import 'dart:async';

import 'package:flutter/services.dart';

import '../car/car_hub.dart';
import 'voice_controller.dart';
import 'voice_port.dart';

/// Error codes of `listen` that [VoiceHeard.error] keeps; anything else is
/// `other`.
const _listenErrors = {'no_match', 'timeout', 'busy', 'audio', 'network', 'permission', 'other'};

/// [VoicePort] over the `agentd/voice` MethodChannel. The channel's handler
/// (buttons, lifecycle) belongs to [VoiceBridge], which feeds [addButton].
class MethodChannelVoicePort implements VoicePort {
  MethodChannelVoicePort([MethodChannel? channel]) : _ch = channel ?? const MethodChannel(voiceChannelName);

  final MethodChannel _ch;
  final _buttons = StreamController<VoiceButton>.broadcast();
  Future<void>? _listenStart;

  /// Use the headset microphone (call quality) while listening; false = the
  /// phone's microphone.
  bool headsetMic = true;

  /// The longest wait for an earcon before the call moves on (a cut tone is
  /// never answered natively).
  static const earconWait = Duration(milliseconds: 800);

  /// A headset button reported by the platform.
  void addButton(VoiceButton b) {
    if (!_buttons.isClosed) _buttons.add(b);
  }

  @override
  Stream<VoiceButton> get buttons => _buttons.stream;

  @override
  Future<void> say(String text) async {
    try {
      await _ch.invokeMethod<void>('say', {'text': text});
    } on PlatformException {
      // TTS failed: the controller goes on as if it had been said.
    } on MissingPluginException {
      // no native side
    }
  }

  @override
  Future<VoiceHeard> listen({Duration max = const Duration(seconds: 8)}) async {
    // The native listen cuts any sound in progress: let the "listening" tone
    // play first.
    final tone = _listenStart;
    _listenStart = null;
    if (tone != null) await tone.timeout(earconWait, onTimeout: () {});
    try {
      final r = await _ch.invokeMethod<Object?>('listen', {'maxMs': max.inMilliseconds, 'headsetMic': headsetMic});
      return heardFrom(r);
    } catch (_) {
      return const VoiceHeard.error('other');
    }
  }

  /// Maps a native `listen` result.
  static VoiceHeard heardFrom(Object? r) {
    if (r is! Map) return const VoiceHeard.error('other');
    final error = r['error'];
    if (error != null) return VoiceHeard.error(error is String && _listenErrors.contains(error) ? error : 'other');
    final alts = r['alts'];
    if (alts is! List) return const VoiceHeard.error('other');
    final list = [for (final a in alts) if (a is String) a];
    return list.isEmpty ? const VoiceHeard.error('no_match') : VoiceHeard(list);
  }

  @override
  Future<void> earcon(Earcon kind) {
    final f = _ch.invokeMethod<void>('earcon', {'kind': kind.name}).catchError((Object _) {});
    if (kind == Earcon.listenStart) _listenStart = f;
    return f.timeout(earconWait, onTimeout: () {});
  }

  @override
  Future<void> stopSpeaking() => _call('stopSpeaking');

  @override
  Future<void> exit() => _call('exit');

  /// The voice notification's text.
  Future<void> state(String text) => _call('state', {'text': text});

  Future<void> _call(String method, [Object? args]) async {
    try {
      await _ch.invokeMethod<void>(method, args);
    } catch (_) {
      // the service is gone: nothing to do
    }
  }

  Future<void> close() => _buttons.close();
}

const voiceChannelName = 'agentd/voice';

/// Builds the controller of one voice mode run (tests inject timers).
typedef VoiceControllerFactory = VoiceController Function(VoicePort port, CarHub hub);

/// Owns the voice mode on the engine: a [VoiceController] per run of the
/// native VoiceService.
///
/// - `started`: reads [headsetMic] and starts a controller. When one is
///   already on (the user opened "agentd voz" again), it is left alone: the
///   conversation keeps its state and a button press talks. A controller
///   that turned itself off (it said "Salgo") is replaced.
/// - `button`: forwarded to the port's [VoicePort.buttons].
/// - `stopped`: the controller is disposed, without speaking.
/// - `route {bt: false}` that lasts [unplugGrace]: the headphones are gone,
///   so voice mode ends without a word (it would come out of the speaker
///   and there is no button left to stop it). Android refuses to start it
///   without Bluetooth audio.
/// - controller states go to the notification text (`state`).
class VoiceBridge {
  VoiceBridge(this.hub, {MethodChannel? channel, this.headsetMic, VoiceControllerFactory? controller, this.unplugGrace = const Duration(seconds: 3)})
      : _ch = channel ?? const MethodChannel(voiceChannelName),
        _factory = controller ?? ((port, hub) => VoiceController(port: port, hub: hub)) {
    port = MethodChannelVoicePort(_ch);
  }

  final CarHub hub;
  final MethodChannel _ch;

  /// How long Bluetooth audio may be missing (a profile switch while the
  /// headset mic opens) before voice mode ends.
  final Duration unplugGrace;
  Timer? _unplug;

  /// Reads the "Micrófono de los auriculares" setting (default true).
  final Future<bool> Function()? headsetMic;
  final VoiceControllerFactory _factory;
  late final MethodChannelVoicePort port;
  VoiceController? _controller;
  StreamSubscription<VoiceState>? _stateSub;

  /// The controller of the current run, if any.
  VoiceController? get controller => _controller;

  /// Registers the channel handler (before the engine sends `ready`).
  void start() => _ch.setMethodCallHandler(handle);

  /// One call from Android.
  Future<Object?> handle(MethodCall call) async {
    final a = call.arguments is Map ? Map<String, Object?>.from(call.arguments as Map) : const <String, Object?>{};
    switch (call.method) {
      case 'started':
        await _start();
      case 'stopped':
        await _stop();
      case 'button':
        final b = VoiceButton.values.where((v) => v.name == a['key']).firstOrNull;
        if (b != null) port.addButton(b);
      case 'route':
        if (a['bt'] == true) {
          _unplug?.cancel();
          _unplug = null;
        } else {
          _unplug ??= Timer(unplugGrace, () {
            _unplug = null;
            unawaited(_unplugged());
          });
        }
      default:
        throw MissingPluginException(call.method);
    }
    return null;
  }

  Future<void> _start() async {
    final cur = _controller;
    if (cur != null && cur.state != VoiceState.off) return;
    if (cur != null) await _stop();
    try {
      port.headsetMic = await (headsetMic?.call() ?? Future.value(true));
    } catch (_) {
      port.headsetMic = true;
    }
    final c = _factory(port, hub);
    _controller = c;
    _stateSub = c.states.listen((s) {
      final text = stateText(s, c.current == null ? null : _agentName(c.current!));
      if (text != null) unawaited(port.state(text));
    });
    await c.start();
  }

  /// The headphones are gone: off without speaking, and the service stops.
  Future<void> _unplugged() async {
    if (_controller == null) return;
    await _stop();
    await port.exit();
  }

  Future<void> _stop() async {
    _unplug?.cancel();
    _unplug = null;
    final c = _controller;
    _controller = null;
    await _stateSub?.cancel();
    _stateSub = null;
    await c?.dispose();
  }

  String? _agentName(String key) {
    for (final a in (hub.snapshot['agents'] as List? ?? const []).whereType<Map<Object?, Object?>>()) {
      if (a['key'] == key) return a['name'] as String?;
    }
    return null;
  }

  /// The notification text for a controller state (null: leave it).
  static String? stateText(VoiceState s, String? agent) => switch (s) {
        VoiceState.listening => 'Escuchando',
        VoiceState.speaking => 'Hablando',
        VoiceState.armed => agent == null ? 'Pulsa para hablar' : 'Con $agent · pulsa para hablar',
        VoiceState.acting || VoiceState.off => null,
      };
}
