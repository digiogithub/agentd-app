// Providers of the dictation feature: the recognizer service (tests override
// it with a fake) and the persisted language choice.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dictation_service.dart';

final dictationServiceProvider = Provider<DictationService>(
  (ref) => SpeechToTextDictation(),
);

/// Where the chosen dictation language is kept.
abstract class DictationLocaleStore {
  Future<String?> load();
  Future<void> save(String? localeId);
}

class PrefsDictationLocaleStore implements DictationLocaleStore {
  PrefsDictationLocaleStore([SharedPreferencesAsync? prefs])
    : _prefs = prefs ?? SharedPreferencesAsync();
  final SharedPreferencesAsync _prefs;
  static const _key = 'dictation.locale';

  @override
  Future<String?> load() async {
    try {
      return await _prefs.getString(_key);
    } catch (_) {
      return null; // prefs not available (plain widget tests): use the default
    }
  }

  @override
  Future<void> save(String? localeId) async {
    try {
      if (localeId == null) {
        await _prefs.remove(_key);
      } else {
        await _prefs.setString(_key, localeId);
      }
    } catch (_) {}
  }
}

final dictationLocaleStoreProvider = Provider<DictationLocaleStore>(
  (ref) => PrefsDictationLocaleStore(),
);

/// The saved language id, or null = automatic (device locale, else es_ES).
class DictationLocaleNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() => ref.read(dictationLocaleStoreProvider).load();

  Future<void> choose(String? localeId) async {
    state = AsyncData(localeId);
    await ref.read(dictationLocaleStoreProvider).save(localeId);
  }
}

final dictationLocaleProvider =
    AsyncNotifierProvider<DictationLocaleNotifier, String?>(
      DictationLocaleNotifier.new,
    );

/// Locales offered by the recognizer (empty when dictation is unavailable).
final dictationLocalesProvider =
    FutureProvider.autoDispose<List<DictationLocale>>(
      (ref) => ref.watch(dictationServiceProvider).locales(),
    );
