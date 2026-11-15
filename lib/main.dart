import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'src/data/data.dart';
import 'src/ui/app.dart';
import 'src/ui/providers.dart';

/// `--dart-define=AGENTD_APP_FAKE=true` runs on the in-memory fakes (demos,
/// screenshots); otherwise the app uses the real repositories.
const bool useFakes = bool.fromEnvironment('AGENTD_APP_FAKE');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(buildApp(data: useFakes ? null : AppData.create()));
}

/// The app root: on [data] (real repositories), or on the fakes when null.
Widget buildApp({AppData? data}) {
  if (data == null) return const ProviderScope(child: AgentdApp());
  return ProviderScope(
    overrides: [
      hostsRepositoryProvider.overrideWithValue(data.hosts),
      sessionsRepositoryProvider.overrideWithValue(data.sessions),
      mailRepositoryProvider.overrideWithValue(data.mail),
      provisionServiceProvider.overrideWithValue(data.provision),
      hostKeyPromptsProvider.overrideWithValue(data.hostKeyPrompts),
    ],
    child: const AgentdApp(),
  );
}
