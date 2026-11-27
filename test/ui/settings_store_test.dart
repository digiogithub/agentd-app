import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings JSON round trip', () {
    const s = AppSettings(notifyExit: true, theme: ThemeChoice.light, muted: [MutedSession('codex@api', '1 h')]);
    final back = appSettingsFromJson(s.toJson());
    expect(back.notifyExit, isTrue);
    expect(back.theme, ThemeChoice.light);
    expect(back.muted.single.session, 'codex@api');
    expect(back.muted.single.until, '1 h');
  });

  test('chat font settings round trip and are clamped', () {
    const s = AppSettings(chatFontSize: 18, chatFont: ChatFont.serif, muted: []);
    final back = appSettingsFromJson(s.toJson());
    expect((back.chatFontSize, back.chatFont), (18.0, ChatFont.serif));
    final bad = appSettingsFromJson({'chatFontSize': 99, 'chatFont': 'comic'});
    expect((bad.chatFontSize, bad.chatFont), (kMaxChatFontSize, ChatFont.sans));
    expect(appSettingsFromJson({}).chatFontSize, kDefaultChatFontSize);
  });

  test('reading fonts and line spacing round trip; unknown spacing is normal', () {
    const s = AppSettings(chatFont: ChatFont.reading, chatLineHeight: ChatLineHeight.wide, muted: []);
    final back = appSettingsFromJson(s.toJson());
    expect((back.chatFont, back.chatLineHeight), (ChatFont.reading, ChatLineHeight.wide));
    expect(appSettingsFromJson({'chatFont': 'legible'}).chatFont, ChatFont.legible);
    expect(appSettingsFromJson({'chatLineHeight': 'huge'}).chatLineHeight, ChatLineHeight.normal);
    expect(chatFontOrder.toSet(), ChatFont.values.toSet());
  });

  test('color schemes round trip; unknown is the standard one', () {
    final back = appSettingsFromJson(const AppSettings(darkScheme: DarkScheme.amoled, lightScheme: LightScheme.cream, muted: []).toJson());
    expect((back.darkScheme, back.lightScheme), (DarkScheme.amoled, LightScheme.cream));
    final bad = appSettingsFromJson({'darkScheme': 'neon', 'lightScheme': 3});
    expect((bad.darkScheme, bad.lightScheme), (DarkScheme.standard, LightScheme.standard));
  });

  test('battery saver round trips; unknown is low', () {
    final back = appSettingsFromJson(const AppSettings(batterySaver: BatterySaver.high, muted: []).toJson());
    expect(back.batterySaver, BatterySaver.high);
    expect(appSettingsFromJson({'batterySaver': 'max'}).batterySaver, BatterySaver.low);
    expect(PowerTuning.of(BatterySaver.high).viewInterval, greaterThan(PowerTuning.of(BatterySaver.medium).viewInterval));
    expect(PowerTuning.of(BatterySaver.medium).suspendAfter, lessThan(PowerTuning.of(BatterySaver.low).suspendAfter));
  });

  test('voice headset mic round trips; missing or broken is on', () {
    expect(appSettingsFromJson(const AppSettings(voiceHeadsetMic: false, muted: []).toJson()).voiceHeadsetMic, isFalse);
    expect(appSettingsFromJson(<String, Object?>{}).voiceHeadsetMic, isTrue);
    expect(appSettingsFromJson({'voiceHeadsetMic': 'no'}).voiceHeadsetMic, isTrue);
    expect(const AppSettings().copyWith(voiceHeadsetMic: false).voiceHeadsetMic, isFalse);
  });

  test('broken or missing settings fall back to defaults without sample mutes', () {
    expect(appSettingsFromJson(null).muted, isEmpty);
    final s = appSettingsFromJson({'theme': 'neon', 'notifyWaiting': 'yes', 'muted': 3});
    expect(s.theme, ThemeChoice.dark);
    expect(s.notifyWaiting, isTrue);
    expect(s.muted, isEmpty);
  });

  test('changes are saved to the store and start from the initial settings', () async {
    final store = MemorySettingsStore();
    final c = ProviderContainer(overrides: [
      settingsStoreProvider.overrideWithValue(store),
      initialSettingsProvider.overrideWithValue(const AppSettings(theme: ThemeChoice.system, muted: [])),
    ]);
    addTearDown(c.dispose);
    expect(c.read(settingsProvider).theme, ThemeChoice.system);
    c.read(settingsProvider.notifier).update((x) => x.copyWith(theme: ThemeChoice.light));
    await Future<void>.delayed(Duration.zero);
    expect((await store.load()).theme, ThemeChoice.light);
  });
}
