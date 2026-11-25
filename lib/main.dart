import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'src/data/data.dart';
import 'src/platform/background.dart';
import 'src/platform/push.dart';
import 'src/ui/app.dart';
import 'src/ui/providers.dart';

/// `--dart-define=AGENTD_APP_FAKE=true` runs on the in-memory fakes (demos,
/// screenshots); otherwise the app uses the real repositories.
const bool useFakes = bool.fromEnvironment('AGENTD_APP_FAKE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (useFakes) {
    runApp(buildApp());
    return;
  }
  final store = PrefsSettingsStore();
  runApp(buildApp(data: AppData.create(), settingsStore: store, settings: await store.load()));
}

/// The app root: on [data] (real repositories), or on the fakes when null.
/// [settingsStore] + [settings] persist the local settings (theme, mutes).
Widget buildApp({AppData? data, SettingsStore? settingsStore, AppSettings? settings}) {
  if (data == null) return const ProviderScope(child: AgentdApp());
  return ProviderScope(
    overrides: [
      if (settingsStore != null) settingsStoreProvider.overrideWithValue(settingsStore),
      if (settings != null) initialSettingsProvider.overrideWithValue(settings),
      hostsRepositoryProvider.overrideWithValue(data.hosts),
      sessionsRepositoryProvider.overrideWithValue(data.sessions),
      mailRepositoryProvider.overrideWithValue(data.mail),
      boardRepositoryProvider.overrideWithValue(data.board),
      devicesRepositoryProvider.overrideWithValue(data.devices),
      pushRepositoryProvider.overrideWithValue(data.push),
      if (Platform.isAndroid || Platform.isIOS) pushMessagingProvider.overrideWithValue(FirebasePushMessaging()),
      provisionServiceProvider.overrideWithValue(data.provision),
      hostKeyPromptsProvider.overrideWithValue(data.hostKeyPrompts),
      if (Platform.isAndroid) backgroundBridgeProvider.overrideWithValue(MethodChannelBackgroundBridge()),
      // agentd://relay?... invite links opened from another app.
      if (Platform.isAndroid || Platform.isIOS) appLinksProvider.overrideWithValue(AppLinks().uriLinkStream),
    ],
    child: const AgentdApp(),
  );
}
