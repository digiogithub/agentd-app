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

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/contracts.dart';
import 'fakes/fake_repositories.dart';

final hostsRepositoryProvider = Provider<HostsRepository>((ref) => FakeHostsRepository());
final sessionsRepositoryProvider = Provider<SessionsRepository>((ref) => FakeSessionsRepository());
final mailRepositoryProvider = Provider<MailRepository>((ref) => FakeMailRepository());
final provisionServiceProvider = Provider<ProvisionService>((ref) => FakeProvisionService());

/// New host keys waiting for the user's decision (TOFU dialog, see app.dart).
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
// Local app settings (in memory for now)
// ---------------------------------------------------------------------------

enum ThemeChoice { dark, light, system }

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
  });

  final bool notifyWaiting;
  final bool notifyTurnDone;
  final bool notifyExit;
  final bool replyFromNotification;
  final bool biometricApprove;
  final ThemeChoice theme;
  final List<MutedSession> muted;

  AppSettings copyWith({
    bool? notifyWaiting,
    bool? notifyTurnDone,
    bool? notifyExit,
    bool? replyFromNotification,
    bool? biometricApprove,
    ThemeChoice? theme,
    List<MutedSession>? muted,
  }) => AppSettings(
    notifyWaiting: notifyWaiting ?? this.notifyWaiting,
    notifyTurnDone: notifyTurnDone ?? this.notifyTurnDone,
    notifyExit: notifyExit ?? this.notifyExit,
    replyFromNotification: replyFromNotification ?? this.replyFromNotification,
    biometricApprove: biometricApprove ?? this.biometricApprove,
    theme: theme ?? this.theme,
    muted: muted ?? this.muted,
  );
}

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => const AppSettings();

  void update(AppSettings Function(AppSettings) f) => state = f(state);

  void unmute(String session) => state = state.copyWith(muted: state.muted.where((m) => m.session != session).toList());
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
