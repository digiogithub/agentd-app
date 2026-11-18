// Riverpod providers consumed by the UI. The repository providers default to
// the in-memory fakes; lib/main.dart overrides them with the real
// repositories of lib/src/data (unless AGENTD_APP_FAKE=true):
//
//   ProviderScope(overrides: [
//     hostsRepositoryProvider.overrideWithValue(data.hosts),
//     sessionsRepositoryProvider.overrideWithValue(data.sessions),
//     mailRepositoryProvider.overrideWithValue(data.mail),
//     provisionServiceProvider.overrideWithValue(data.provision),
//     hostKeyPromptsProvider.overrideWithValue(data.hostKeyPrompts),
//   ], child: const AgentdApp())

import '../platform/background.dart';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/contracts.dart';
import 'fakes/fake_repositories.dart';

final hostsRepositoryProvider = Provider<HostsRepository>((ref) => FakeHostsRepository());
final sessionsRepositoryProvider = Provider<SessionsRepository>((ref) => FakeSessionsRepository());
final mailRepositoryProvider = Provider<MailRepository>((ref) => FakeMailRepository());
final provisionServiceProvider = Provider<ProvisionService>((ref) => FakeProvisionService());

/// New host keys waiting for the user's decision (TOFU dialog, see app.dart).
/// Android background connection + notifications (main.dart overrides it on
/// Android); a no-op elsewhere and in tests.
final backgroundBridgeProvider = Provider<BackgroundBridge>((ref) => NoopBackgroundBridge());

final hostKeyPromptsProvider = Provider<HostKeyPrompts>((ref) => HostKeyPrompts());

/// Saved hosts with their live state.
final hostsProvider = StreamProvider<List<HostStatus>>((ref) => ref.watch(hostsRepositoryProvider).watch());

/// Every session of every connected host.
final sessionsProvider = StreamProvider<List<AgentSession>>((ref) => ref.watch(sessionsRepositoryProvider).watch());

/// Project names (agentd aliases) of a host, for the new-session chips.
final projectsProvider = FutureProvider.autoDispose.family<List<String>, String>((ref, hostId) => ref.watch(sessionsRepositoryProvider).projects(hostId));

final inboxProvider = StreamProvider.family<List<MailMessage>, String>((ref, hostId) => ref.watch(mailRepositoryProvider).inbox(hostId));

final queuesProvider = StreamProvider.family<List<WorkQueue>, String>((ref, hostId) => ref.watch(mailRepositoryProvider).queues(hostId));

/// Host name by id ('' when unknown), for subtitles.
final hostNamesProvider = Provider<Map<String, String>>((ref) {
  final hosts = ref.watch(hostsProvider).value ?? const [];
  return {for (final h in hosts) h.config.id: h.config.name};
});

// ---------------------------------------------------------------------------
// Local app settings (persisted by SettingsStore; in memory on the fakes)
// ---------------------------------------------------------------------------

enum ThemeChoice { dark, light, system }

/// How the Agents screen groups sessions.
enum AgentsGrouping { project, status }

class MutedSession {
  const MutedSession(this.session, this.until);
  final String session;
  final String until; // human text: "hasta mañana"
}

class AppSettings {
  const AppSettings({
    this.notifyWaiting = true,
    this.notifyTurnDone = true,
    this.notifyExit = false,
    this.replyFromNotification = true,
    this.biometricApprove = true,
    this.theme = ThemeChoice.dark,
    this.muted = const [MutedSession('claude@docs', 'hasta mañana')],
    this.agentsGrouping = AgentsGrouping.project,
    this.chatFontSize = kDefaultChatFontSize,
    this.chatFont = ChatFont.sans,
    this.keepConnected = true,
  });

  final bool notifyWaiting;
  final bool notifyTurnDone;
  final bool notifyExit;
  final bool replyFromNotification;
  final bool biometricApprove;
  final ThemeChoice theme;
  final List<MutedSession> muted;
  final AgentsGrouping agentsGrouping;

  /// Size of the chat view's prose (kMinChatFontSize..kMaxChatFontSize).
  final double chatFontSize;

  /// Font of the chat view's prose.
  final ChatFont chatFont;

  /// Android: while a host is online keep a "connected" notification (a
  /// foreground service) so connections and agent notifications survive in
  /// the background.
  final bool keepConnected;

  AppSettings copyWith({
    bool? notifyWaiting,
    bool? notifyTurnDone,
    bool? notifyExit,
    bool? replyFromNotification,
    bool? biometricApprove,
    ThemeChoice? theme,
    List<MutedSession>? muted,
    AgentsGrouping? agentsGrouping,
    double? chatFontSize,
    ChatFont? chatFont,
    bool? keepConnected,
  }) => AppSettings(
    notifyWaiting: notifyWaiting ?? this.notifyWaiting,
    notifyTurnDone: notifyTurnDone ?? this.notifyTurnDone,
    notifyExit: notifyExit ?? this.notifyExit,
    replyFromNotification: replyFromNotification ?? this.replyFromNotification,
    biometricApprove: biometricApprove ?? this.biometricApprove,
    theme: theme ?? this.theme,
    muted: muted ?? this.muted,
    agentsGrouping: agentsGrouping ?? this.agentsGrouping,
    chatFontSize: chatFontSize ?? this.chatFontSize,
    chatFont: chatFont ?? this.chatFont,
    keepConnected: keepConnected ?? this.keepConnected,
  );
}

const double kDefaultChatFontSize = 14.5;
const double kMinChatFontSize = 11;
const double kMaxChatFontSize = 24;

/// Chat prose fonts: Inter, a serif (Noto Serif), JetBrains Mono.
enum ChatFont { sans, serif, mono }

/// Label of a chat font.
String chatFontLabel(ChatFont f) => switch (f) {
  ChatFont.sans => 'Sans',
  ChatFont.serif => 'Serif',
  ChatFont.mono => 'Mono',
};

extension AppSettingsJson on AppSettings {
  Map<String, Object?> toJson() => {
    'notifyWaiting': notifyWaiting,
    'notifyTurnDone': notifyTurnDone,
    'notifyExit': notifyExit,
    'replyFromNotification': replyFromNotification,
    'biometricApprove': biometricApprove,
    'theme': theme.name,
    'muted': [for (final m in muted) {'session': m.session, 'until': m.until}],
    'agentsGrouping': agentsGrouping.name,
    'chatFontSize': chatFontSize,
    'chatFont': chatFont.name,
    'keepConnected': keepConnected,
  };
}

/// Decodes stored settings; unknown or broken fields keep [fallback]'s values.
AppSettings appSettingsFromJson(Object? json, {AppSettings fallback = const AppSettings(muted: [])}) {
  if (json is! Map) return fallback;
  bool b(String k, bool d) => json[k] is bool ? json[k] as bool : d;
  final theme = ThemeChoice.values.where((t) => t.name == json['theme']).firstOrNull ?? fallback.theme;
  final grouping = AgentsGrouping.values.where((g) => g.name == json['agentsGrouping']).firstOrNull ?? fallback.agentsGrouping;
  final chatFont = ChatFont.values.where((f) => f.name == json['chatFont']).firstOrNull ?? fallback.chatFont;
  final size = json['chatFontSize'];
  final chatFontSize = size is num ? size.toDouble().clamp(kMinChatFontSize, kMaxChatFontSize) : fallback.chatFontSize;
  final muted = <MutedSession>[];
  if (json['muted'] is List) {
    for (final m in json['muted'] as List) {
      if (m is Map && m['session'] is String && m['until'] is String) muted.add(MutedSession(m['session'] as String, m['until'] as String));
    }
  }
  return AppSettings(
    notifyWaiting: b('notifyWaiting', fallback.notifyWaiting),
    notifyTurnDone: b('notifyTurnDone', fallback.notifyTurnDone),
    notifyExit: b('notifyExit', fallback.notifyExit),
    replyFromNotification: b('replyFromNotification', fallback.replyFromNotification),
    biometricApprove: b('biometricApprove', fallback.biometricApprove),
    theme: theme,
    muted: json['muted'] is List ? muted : fallback.muted,
    agentsGrouping: grouping,
    chatFontSize: chatFontSize,
    chatFont: chatFont,
    keepConnected: b('keepConnected', fallback.keepConnected),
  );
}

/// Where the settings live between runs.
abstract class SettingsStore {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

/// Memory only (fakes, tests): starts from the mockup defaults.
class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this._s = const AppSettings()]);
  AppSettings _s;
  @override
  Future<AppSettings> load() async => _s;
  @override
  Future<void> save(AppSettings settings) async => _s = settings;
}

/// shared_preferences, key `agentd.settings.v1` (JSON).
class PrefsSettingsStore implements SettingsStore {
  PrefsSettingsStore([SharedPreferencesAsync? prefs]) : _prefs = prefs ?? SharedPreferencesAsync();
  static const key = 'agentd.settings.v1';
  final SharedPreferencesAsync _prefs;

  @override
  Future<AppSettings> load() async {
    try {
      final raw = await _prefs.getString(key);
      return appSettingsFromJson(raw == null ? null : jsonDecode(raw));
    } catch (_) {
      return const AppSettings(muted: []);
    }
  }

  @override
  Future<void> save(AppSettings settings) => _prefs.setString(key, jsonEncode(settings.toJson()));
}

final settingsStoreProvider = Provider<SettingsStore>((ref) => MemorySettingsStore());

/// Settings loaded before the first frame (main.dart overrides it), so the
/// first frame already has the right theme.
final initialSettingsProvider = Provider<AppSettings>((ref) => const AppSettings());

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialSettingsProvider);

  void update(AppSettings Function(AppSettings) f) => _set(f(state));

  void unmute(String session) => _set(state.copyWith(muted: state.muted.where((m) => m.session != session).toList()));

  void _set(AppSettings s) {
    state = s;
    ref.read(settingsStoreProvider).save(s).catchError((Object _) {});
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
