// Speech-to-text boundary for the chat composer. The UI only talks to
// [DictationService]; the real implementation wraps speech_to_text, tests
// override `dictationServiceProvider` with a fake. Transcribed text is never
// logged.

import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart'
    show SpeechRecognitionError;
import 'package:speech_to_text/speech_to_text.dart' as stt;

enum DictationAvailability { available, permissionDenied, unavailable }

enum DictationStatus { idle, listening }

enum DictationError { permissionDenied, unavailable, other }

class DictationLocale {
  const DictationLocale(this.id, this.name);

  /// Recognizer id such as `es_ES` or `en-US` (the platform decides the separator).
  final String id;
  final String name;

  @override
  bool operator ==(Object other) => other is DictationLocale && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

abstract class DictationService {
  /// Prepares the recognizer (asks for the microphone permission the first
  /// time). Safe to call repeatedly.
  Future<DictationAvailability> initialize();

  /// Starts listening. [onResult] gets the whole phrase heard so far, and
  /// `isFinal` true once for the last one. [onSoundLevel] is normalised 0..1.
  Future<void> listen({
    String? localeId,
    required void Function(String text, bool isFinal) onResult,
    void Function(double level)? onSoundLevel,
  });

  /// Stops listening; the recognizer still delivers the final result.
  Future<void> stop();

  /// Stops listening and drops any pending result.
  Future<void> cancel();

  Stream<DictationStatus> get status;
  Stream<DictationError> get errors;

  /// Locales the recognizer supports (empty when unavailable).
  Future<List<DictationLocale>> locales();

  /// The device's default recognition locale, if known.
  Future<String?> systemLocaleId();
}

/// Picks the dictation language: [saved] if the recognizer has it, else the
/// device locale if supported, else `es_ES` (or the first locale as a last
/// resort when `es_ES` is not offered either).
String pickDictationLocale({
  String? saved,
  String? device,
  required List<DictationLocale> supported,
}) {
  String norm(String s) => s.replaceAll('-', '_').toLowerCase();
  String? find(String? want) {
    if (want == null || want.isEmpty) return null;
    for (final l in supported) {
      if (norm(l.id) == norm(want)) return l.id;
    }
    return null;
  }

  return find(saved) ??
      find(device) ??
      find('es_ES') ??
      (supported.isNotEmpty ? supported.first.id : 'es_ES');
}

class SpeechToTextDictation implements DictationService {
  SpeechToTextDictation([stt.SpeechToText? speech])
    : _speech = speech ?? stt.SpeechToText();

  final stt.SpeechToText _speech;
  final _status = StreamController<DictationStatus>.broadcast();
  final _errors = StreamController<DictationError>.broadcast();
  bool _ready = false;
  bool _permissionError = false;
  double _minLevel = 0, _maxLevel = 1;

  @override
  Stream<DictationStatus> get status => _status.stream;

  @override
  Stream<DictationError> get errors => _errors.stream;

  @override
  Future<DictationAvailability> initialize() async {
    if (_ready) return DictationAvailability.available;
    _permissionError = false;
    bool ok;
    try {
      ok = await _speech.initialize(onError: _onError, onStatus: _onStatus);
    } catch (_) {
      return DictationAvailability.unavailable;
    }
    _ready = ok;
    if (ok) return DictationAvailability.available;
    return _permissionError
        ? DictationAvailability.permissionDenied
        : DictationAvailability.unavailable;
  }

  void _onStatus(String s) {
    // 'listening' | 'notListening' | 'done'
    _status.add(
      s == 'listening' ? DictationStatus.listening : DictationStatus.idle,
    );
  }

  void _onError(dynamic e) {
    final msg = (e is SpeechRecognitionError ? e.errorMsg : '$e');
    if (msg.contains('permission')) {
      _permissionError = true;
      _errors.add(DictationError.permissionDenied);
    } else if (msg == 'error_no_match' || msg == 'error_speech_timeout') {
      // Nothing was said: not worth a message.
    } else if (msg.contains('recognizer_not_available') ||
        msg.contains('not_available')) {
      _errors.add(DictationError.unavailable);
    } else {
      _errors.add(DictationError.other);
    }
  }

  @override
  Future<void> listen({
    String? localeId,
    required void Function(String text, bool isFinal) onResult,
    void Function(double level)? onSoundLevel,
  }) async {
    _minLevel = 0;
    _maxLevel = 1;
    await _speech.listen(
      onResult: (r) => onResult(r.recognizedWords, r.finalResult),
      onSoundLevelChange: onSoundLevel == null
          ? null
          : (db) {
              // Android reports about -2..10 dB, iOS about -50..0: normalise
              // against the range seen so far.
              if (db < _minLevel) _minLevel = db;
              if (db > _maxLevel) _maxLevel = db;
              final span = _maxLevel - _minLevel;
              onSoundLevel(
                span <= 0 ? 0 : ((db - _minLevel) / span).clamp(0.0, 1.0),
              );
            },
      listenOptions: stt.SpeechListenOptions(
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 5),
        localeId: localeId,
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
        onDevice: false, // the platform picks on-device when it can
        cancelOnError: true,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();

  @override
  Future<List<DictationLocale>> locales() async {
    if (!_ready && await initialize() != DictationAvailability.available) {
      return const [];
    }
    final l = await _speech.locales();
    return [for (final x in l) DictationLocale(x.localeId, x.name)];
  }

  @override
  Future<String?> systemLocaleId() async {
    if (!_ready && await initialize() != DictationAvailability.available) {
      return null;
    }
    return (await _speech.systemLocale())?.localeId;
  }
}
