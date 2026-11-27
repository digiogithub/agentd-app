// Light/dark/system theme: palette resolution and live switching.

import 'package:agentd_app/src/ui/app.dart';
import 'package:agentd_app/src/ui/providers.dart';
import 'package:agentd_app/src/ui/screens/settings_screen.dart';
import 'package:agentd_app/src/ui/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

void main() {
  setUp(setUpUiTests);
  tearDown(() => AppColors.palette = AppPalette.dark);

  test('choice x platform brightness resolves to a palette', () {
    for (final b in Brightness.values) {
      expect(AppPalette.resolve(ThemeChoice.dark, b), same(AppPalette.dark));
      expect(AppPalette.resolve(ThemeChoice.light, b), same(AppPalette.light));
    }
    expect(
      AppPalette.resolve(ThemeChoice.system, Brightness.dark),
      same(AppPalette.dark),
    );
    expect(
      AppPalette.resolve(ThemeChoice.system, Brightness.light),
      same(AppPalette.light),
    );
    expect(AppPalette.light.brightness, Brightness.light);
    expect(AppPalette.dark.terminalBg, AppPalette.light.terminalBg);
  });

  test('schemes: each brightness has its own, and they read well (WCAG contrast)', () {
    expect(AppPalette.resolve(ThemeChoice.dark, Brightness.light, darkScheme: DarkScheme.mocha), same(AppPalette.mocha));
    expect(AppPalette.resolve(ThemeChoice.system, Brightness.light, darkScheme: DarkScheme.mocha, lightScheme: LightScheme.cream), same(AppPalette.cream));
    expect(AppPalette.resolve(ThemeChoice.system, Brightness.dark, darkScheme: DarkScheme.amoled), same(AppPalette.amoled));
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
    }

    final all = {
      for (final d in DarkScheme.values) 'dark ${d.name}': (AppPalette.ofDark(d), Brightness.dark),
      for (final l in LightScheme.values) 'light ${l.name}': (AppPalette.ofLight(l), Brightness.light),
    };
    for (final MapEntry(key: name, value: (p, b)) in all.entries) {
      expect(p.brightness, b, reason: name);
      for (final bg in [p.bg, p.surface]) {
        expect(contrast(p.text, bg), greaterThanOrEqualTo(7), reason: '$name text');
        expect(contrast(p.secondary, bg), greaterThanOrEqualTo(4.5), reason: '$name secondary');
        expect(contrast(p.muted, bg), greaterThanOrEqualTo(4.5), reason: '$name muted');
      }
      expect(contrast(p.accent, p.surface), greaterThanOrEqualTo(3), reason: '$name accent');
      expect(contrast(p.text, p.raised2), greaterThanOrEqualTo(4.5), reason: '$name raised');
    }
  });

  test('buildAppTheme follows the palette', () {
    final t = buildAppTheme(AppPalette.light);
    expect(t.brightness, Brightness.light);
    expect(t.scaffoldBackgroundColor, AppPalette.light.bg);
  });

  Color scaffoldColor(WidgetTester tester) =>
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor ??
      Theme.of(tester.element(find.byType(Scaffold).first))
          .scaffoldBackgroundColor;

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await tester.pumpWidget(
      ProviderScope(overrides: Fakes().overrides, child: const AgentdApp()),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('choosing Claro repaints in place and keeps the open route', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(scaffoldColor(tester), AppPalette.dark.bg);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('ruta abierta')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ruta abierta'), findsOneWidget);

    ProviderScope.containerOf(tester.element(find.byType(Navigator).first))
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(theme: ThemeChoice.light));
    await tester.pumpAndSettle();
    expect(scaffoldColor(tester), AppPalette.light.bg);
    expect(AppColors.bg, AppPalette.light.bg);
    expect(find.text('ruta abierta'), findsOneWidget);
    nav.pop();
    await tester.pumpAndSettle();
    // The shell below was repainted too.
    expect(
      find
          .byType(Scaffold)
          .evaluate()
          .map(
            (e) =>
                (e.widget as Scaffold).backgroundColor ??
                Theme.of(e).scaffoldBackgroundColor,
          ),
      everyElement(AppPalette.light.bg),
    );
  });

  testWidgets('the Settings control switches the theme', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Ajustes'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Claro'), 300);
    await tester.tap(find.text('Claro'));
    await tester.pumpAndSettle();
    expect(AppColors.palette, same(AppPalette.light));
    expect(find.textContaining('llegará pronto'), findsNothing);
    await tester.tap(find.text('Oscuro'));
    await tester.pumpAndSettle();
    expect(AppColors.palette, same(AppPalette.dark));
  });

  testWidgets('the scheme pickers apply Moka and Crema', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Ajustes'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Esquema oscuro'), 300);
    await tester.tap(find.text('Esquema oscuro'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scheme-DarkScheme.mocha')));
    await tester.pumpAndSettle();
    expect(AppColors.palette, same(AppPalette.mocha));
    expect(find.text('Moka (Catppuccin)'), findsOneWidget);
    // The light scheme is kept for Claro and does not change the dark theme.
    await tester.tap(find.text('Esquema claro'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scheme-LightScheme.cream')));
    await tester.pumpAndSettle();
    expect(AppColors.palette, same(AppPalette.mocha));
    await tester.tap(find.text('Claro'));
    await tester.pumpAndSettle();
    expect(AppColors.palette, same(AppPalette.cream));
  });

  testWidgets('Sistema follows the platform brightness', (tester) async {
    await pumpApp(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Navigator).first),
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    container
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(theme: ThemeChoice.system));
    await tester.pumpAndSettle();
    expect(scaffoldColor(tester), AppPalette.dark.bg);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(scaffoldColor(tester), AppPalette.light.bg);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(scaffoldColor(tester), AppPalette.dark.bg);
  });
}
