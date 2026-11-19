// App root and the bottom-nav shell (Agentes, Hosts, Buzón, Ajustes).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:material_ui/material_ui.dart';

import '../core/contracts.dart';
import 'background_controller.dart';
import 'providers.dart';
import 'screens/add_host_screen.dart';
import 'screens/session_screen.dart';
import 'screens/agents_screen.dart';
import 'screens/hosts_screen.dart';
import 'screens/mailbox_screen.dart';
import 'screens/settings_screen.dart';
import 'theme.dart';
import 'widgets/bottom_nav.dart';
import 'widgets/host_key_dialog.dart';

/// Root widget. Wrap it in a ProviderScope (overrides in providers.dart).
///
/// Resolves the theme choice (and, for "Sistema", the platform brightness)
/// into an [AppPalette], publishes it in [AppColors.palette] and repaints the
/// whole tree when it changes. Screens keep their state and the navigator
/// keeps its routes: every element is only marked dirty.
class AgentdApp extends ConsumerStatefulWidget {
  const AgentdApp({super.key});

  @override
  ConsumerState<AgentdApp> createState() => _AgentdAppState();
}

class _AgentdAppState extends ConsumerState<AgentdApp>
    with WidgetsBindingObserver {
  Brightness get _platform =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  late final BackgroundController _background;
  StreamSubscription<String>? _opens;
  StreamSubscription<Uri>? _links;
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _background = BackgroundController(
      hosts: ref.read(hostsRepositoryProvider),
      sessions: ref.read(sessionsRepositoryProvider),
      bridge: ref.read(backgroundBridgeProvider),
      settings: () => ref.read(settingsProvider),
    )..start();
    _opens = _background.opens.listen(_openSession);
    _links = ref.read(appLinksProvider).listen(_openLink, onError: (Object _) {});
    // First frame: nothing is built yet, so no repaint walk is needed.
    AppColors.palette = AppPalette.resolve(
      ref.read(settingsProvider).theme,
      _platform,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _opens?.cancel();
    _links?.cancel();
    unawaited(_background.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _background.setForeground(true);
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        _background.setForeground(false);
      case AppLifecycleState.inactive:
        break; // notification shade, app switcher: still on screen
    }
  }

  /// A tapped agent notification: open that session.
  void _openSession(String key) {
    final s = ref.read(sessionsProvider).value?.where((x) => x.key == key).firstOrNull;
    final nav = _navigator.currentState;
    if (s == null || nav == null) return;
    nav.push(MaterialPageRoute<void>(builder: (_) => SessionScreen(session: s)));
  }

  /// An `agentd://relay?...` invite opened from another app (or the camera):
  /// Añadir host with the link filled in. The link is never logged.
  void _openLink(Uri uri) {
    if (uri.scheme != 'agentd' || uri.host != 'relay') return;
    void push() {
      final nav = _navigator.currentState;
      if (nav == null) return;
      nav.push(MaterialPageRoute<void>(builder: (_) => AddHostScreen(relayLink: uri.toString())));
    }

    // A cold start delivers the link before the navigator exists.
    if (_navigator.currentState == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => push());
    } else {
      push();
    }
  }

  @override
  void didChangePlatformBrightness() =>
      _apply(ref.read(settingsProvider).theme);

  /// Switches to the palette for [choice]; repaints everything if it changed.
  void _apply(ThemeChoice choice) {
    final next = AppPalette.resolve(choice, _platform);
    if (identical(next, AppColors.palette)) return;
    setState(() => AppColors.palette = next);
    _rebuildAll(context as Element);
  }

  /// Many widgets are const or cached and read [AppColors] only in build, so
  /// the new palette reaches them only if they rebuild: mark every element.
  static void _rebuildAll(Element root) {
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    visit(root);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsProvider.select((s) => s.theme), (_, t) => _apply(t));
    ref.listen(settingsProvider.select((s) => s.keepConnected), (_, _) => _background.settingsChanged());
    final p = AppColors.palette;
    final dark = p.brightness == Brightness.dark;
    final theme = buildAppTheme(p);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: const Color(0x00000000),
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: p.navBg,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
      ),
      child: MaterialApp(
        navigatorKey: _navigator,
        title: 'agentd',
        debugShowCheckedModeBanner: false,
        theme: theme,
        darkTheme: theme,
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        themeAnimationDuration: Duration.zero,
        home: const AppShell(),
      ),
    );
  }
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
    body: IndexedStack(
      index: _index,
      children: const [
        AgentsScreen(),
        HostsScreen(),
        MailboxScreen(),
        SettingsScreen(),
      ],
    ),
    bottomNavigationBar: AppBottomNav(
      index: _index,
      onTap: (i) => setState(() => _index = i),
    ),
  );
}
