// The platform side of the hands-free voice mode, as the controller sees it:
// speech out, one speech recognition, short sounds and the headset buttons.
// The Android implementation sits behind the MethodChannel `agentd/voice`
// (text-to-speech, SpeechRecognizer, earcons, media session buttons); tests
// use a scripted fake. Never log what is said or heard.

/// A headset (media) button press.
enum VoiceButton { playPause, next, previous }

/// A short sound: listening starts or ends, an action worked or failed.
enum Earcon { listenStart, listenEnd, ok, error }

/// What one recognition heard: up to five alternatives, best first, or an
/// [error] code with no alternatives.
class VoiceHeard {
  const VoiceHeard(this.alts, {this.error});
  const VoiceHeard.error(String this.error) : alts = const [];

  /// Recognition alternatives, best first (may be empty).
  final List<String> alts;

  /// `no_match` (nothing understood), `timeout` (silence), `busy`
  /// (recognizer in use), `audio` (microphone), `network`, `permission`
  /// (no microphone permission), `other`.
  final String? error;

  /// Nothing usable was heard.
  bool get isEmpty => alts.every((a) => a.trim().isEmpty);

  /// Silence or nothing understood (worth asking again).
  bool get isSilence => isEmpty && (error == null || error == 'no_match' || error == 'timeout');
}

abstract class VoicePort {
  /// Speaks [text]; completes when the speech ends or [stopSpeaking] cuts it.
  Future<void> say(String text);

  /// One recognition, of at most [max]; silence comes back as `timeout`.
  Future<VoiceHeard> listen({Duration max = const Duration(seconds: 8)});

  /// Plays a short sound; completes when it has been started.
  Future<void> earcon(Earcon kind);

  /// Cuts the speech in progress (its [say] completes). No-op when silent.
  Future<void> stopSpeaking();

  /// Headset button presses while voice mode is on.
  Stream<VoiceButton> get buttons;

  /// The controller ends voice mode: the platform releases the audio focus,
  /// the media session and the foreground service.
  Future<void> exit();
}
