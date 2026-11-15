// App root and the bottom-nav shell (Agentes, Hosts, Buzón, Ajustes).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/contracts.dart';
import 'providers.dart';
import 'screens/agents_screen.dart';
import 'screens/hosts_screen.dart';
import 'screens/mailbox_screen.dart';
import 'screens/settings_screen.dart';
import 'theme.dart';
import 'widgets/bottom_nav.dart';
import 'widgets/host_key_dialog.dart';

/// Root widget. Wrap it in a ProviderScope (overrides in providers.dart).
class AgentdApp extends StatelessWidget {
  const AgentdApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'agentd',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    darkTheme: buildAppTheme(),
    themeMode: ThemeMode.dark,
    home: const AppShell(),
  );
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, this.initialIndex = 0});
  final int initialIndex;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late int _index = widget.initialIndex;
  StreamSubscription<HostKeyPrompt>? _prompts;

  @override
  void initState() {
    super.initState();
    // New host keys (trust on first use) are confirmed in a dialog on top of
    // whatever screen is open.
    _prompts = ref.read(hostKeyPromptsProvider).stream.listen((p) async {
      if (!mounted) return p.reply(false);
      final ok = await showHostKeyDialog(context, p);
      p.reply(ok);
    });
  }

  @override
  void dispose() {
    _prompts?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(index: _index, children: const [AgentsScreen(), HostsScreen(), MailboxScreen(), SettingsScreen()]),
    bottomNavigationBar: AppBottomNav(index: _index, onTap: (i) => setState(() => _index = i)),
  );
}
