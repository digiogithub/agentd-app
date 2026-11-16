// Dark theme, palette and text styles of the validated mockups.

import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';

import '../core/contracts.dart';
import 'providers.dart' show ThemeChoice;

/// Every color of the app for one brightness. Names follow their role.
class AppPalette {
  const AppPalette({
    required this.bg,
    required this.surface,
    required this.raised,
    required this.raised2,
    required this.border,
    required this.divider,
    required this.navBg,
    required this.terminalBg,
    required this.text,
    required this.secondary,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accentBg,
    required this.accentLight,
    required this.waiting,
    required this.waitingBg,
    required this.waitingBorder,
    required this.questionBg,
    required this.questionBorder,
    required this.onWaiting,
    required this.working,
    required this.workingBg,
    required this.onWorking,
    required this.success,
    required this.successBg,
    required this.successText,
    required this.danger,
    required this.dangerBg,
    required this.dangerBorder,
  });

  final Color bg;
  final Color surface;
  final Color raised;
  final Color raised2;
  final Color border;
  final Color divider;
  final Color navBg;
  final Color terminalBg;
  final Color text;
  final Color secondary;
  final Color muted;
  final Color faint;
  final Color accent;
  final Color accentBg;
  final Color accentLight;
  final Color waiting;
  final Color waitingBg;
  final Color waitingBorder;
  final Color questionBg;
  final Color questionBorder;
  final Color onWaiting;
  final Color working;
  final Color workingBg;
  final Color onWorking;
  final Color success;
  final Color successBg;
  final Color successText;
  final Color danger;
  final Color dangerBg;
  final Color dangerBorder;

  static const dark = AppPalette(
    bg: Color(0xFF0D1117),
    surface: Color(0xFF161B22),
    raised: Color(0xFF1F2630),
    raised2: Color(0xFF262E3A),
    border: Color(0xFF2A3340),
    divider: Color(0xFF1F2630),
    navBg: Color(0xFF10151C),
    terminalBg: Color(0xFF07090D),
    text: Color(0xFFE6EDF3),
    secondary: Color(0xFFC9D4DF),
    muted: Color(0xFF9AA7B4),
    faint: Color(0xFF6E7B88),
    accent: Color(0xFF9DB4FF),
    accentBg: Color(0xFF1B2233),
    accentLight: Color(0xFFC3D1FF),
    waiting: Color(0xFFF0A04B),
    waitingBg: Color(0xFF2B2116),
    waitingBorder: Color(0xFF3A2E1E),
    questionBg: Color(0xFF1A1610),
    questionBorder: Color(0xFF5A4220),
    onWaiting: Color(0xFF1A1206),
    working: Color(0xFF58A6FF),
    workingBg: Color(0xFF13233A),
    onWorking: Color(0xFF08172B),
    success: Color(0xFF3FB950),
    successBg: Color(0xFF12261A),
    successText: Color(0xFF7EE2A0),
    danger: Color(0xFFFF9B9B),
    dangerBg: Color(0xFF2A1515),
    dangerBorder: Color(0xFF5A2A2A),
  );

  static const light = AppPalette(
    bg: Color(0xFFF6F8FA),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFEEF1F5),
    raised2: Color(0xFFE4E8EE),
    border: Color(0xFFD0D7DE),
    divider: Color(0xFFE4E8EE),
    navBg: Color(0xFFFFFFFF),
    terminalBg: Color(0xFF07090D),
    text: Color(0xFF1F2328),
    secondary: Color(0xFF3D4651),
    muted: Color(0xFF59636E),
    faint: Color(0xFF818B96),
    accent: Color(0xFF3B5BDB),
    accentBg: Color(0xFFE7ECFF),
    accentLight: Color(0xFF2A44A8),
    waiting: Color(0xFFB86200),
    waitingBg: Color(0xFFFFF1E0),
    waitingBorder: Color(0xFFF2D3A8),
    questionBg: Color(0xFFFFF8EE),
    questionBorder: Color(0xFFE0B477),
    onWaiting: Color(0xFFFFFFFF),
    working: Color(0xFF0969DA),
    workingBg: Color(0xFFDDEEFF),
    onWorking: Color(0xFFFFFFFF),
    success: Color(0xFF1A7F37),
    successBg: Color(0xFFDAFBE1),
    successText: Color(0xFF116329),
    danger: Color(0xFFCF222E),
    dangerBg: Color(0xFFFFEBE9),
    dangerBorder: Color(0xFFF5C2C0),
  );

  static AppPalette of(Brightness b) => b == Brightness.dark ? dark : light;

  /// Palette for a user choice, given the platform brightness (for `system`).
  static AppPalette resolve(ThemeChoice choice, Brightness platform) => switch (choice) {
    ThemeChoice.dark => dark,
    ThemeChoice.light => light,
    ThemeChoice.system => of(platform),
  };

  Brightness get brightness => identical(this, light) ? Brightness.light : Brightness.dark;
}

/// Palette of the mockups. Same names as always, but read from the active
/// [palette] (set by the app root when the theme choice changes), so no call
/// site can be `const`.
abstract final class AppColors {
  static AppPalette palette = AppPalette.dark;

  static Color get bg => palette.bg;
  static Color get surface => palette.surface;
  static Color get raised => palette.raised;
  static Color get raised2 => palette.raised2;
  static Color get border => palette.border;
  static Color get divider => palette.divider;
  static Color get navBg => palette.navBg;
  static Color get terminalBg => palette.terminalBg;
  static Color get text => palette.text;
  static Color get secondary => palette.secondary;
  static Color get muted => palette.muted;
  static Color get faint => palette.faint;
  static Color get accent => palette.accent;
  static Color get accentBg => palette.accentBg;
  static Color get accentLight => palette.accentLight;
  static Color get waiting => palette.waiting;
  static Color get waitingBg => palette.waitingBg;
  static Color get waitingBorder => palette.waitingBorder;
  static Color get questionBg => palette.questionBg;
  static Color get questionBorder => palette.questionBorder;
  static Color get onWaiting => palette.onWaiting;
  static Color get working => palette.working;
  static Color get workingBg => palette.workingBg;
  static Color get onWorking => palette.onWorking;
  static Color get success => palette.success;
  static Color get successBg => palette.successBg;
  static Color get successText => palette.successText;
  static Color get danger => palette.danger;
  static Color get dangerBg => palette.dangerBg;
  static Color get dangerBorder => palette.dangerBorder;
}

/// Fonts: Inter for UI, JetBrains Mono for code. Google Fonts is used only
/// when runtime fetching is allowed (tests turn it off): otherwise the plain
/// family names are used and the platform falls back.
abstract final class AppFonts {
  static bool get _google => GoogleFonts.config.allowRuntimeFetching;

  static TextStyle inter({double size = 14, FontWeight weight = FontWeight.w400, Color? color, double? height, double? letterSpacing}) {
    final base = TextStyle(fontSize: size, fontWeight: weight, color: color ?? AppColors.text, height: height, letterSpacing: letterSpacing);
    return _google ? GoogleFonts.inter(textStyle: base) : base.copyWith(fontFamily: 'Inter');
  }

  static TextStyle mono({double size = 13, FontWeight weight = FontWeight.w400, Color? color, double? height}) {
    final base = TextStyle(fontSize: size, fontWeight: weight, color: color ?? AppColors.secondary, height: height);
    return _google ? GoogleFonts.jetBrainsMono(textStyle: base) : base.copyWith(fontFamily: 'JetBrains Mono', fontFamilyFallback: const ['monospace']);
  }

  static String get monoFamily => _google ? GoogleFonts.jetBrainsMono().fontFamily ?? 'monospace' : 'monospace';
}

/// Text styles used across screens (sizes from the mockups).
abstract final class AppText {
  static TextStyle get screenTitle => AppFonts.inter(size: 28, weight: FontWeight.w700, letterSpacing: -0.56);
  static TextStyle get routeTitle => AppFonts.inter(size: 20, weight: FontWeight.w700);
  static TextStyle get overline => AppFonts.inter(size: 13, color: AppColors.muted);
  static TextStyle get sectionLabel => AppFonts.inter(size: 12, weight: FontWeight.w600, color: AppColors.muted, letterSpacing: 0.72);
  static TextStyle get cardTitle => AppFonts.inter(size: 15, weight: FontWeight.w600);
  static TextStyle get body => AppFonts.inter(size: 14, color: AppColors.secondary, height: 1.45);
  static TextStyle get caption => AppFonts.inter(size: 12, color: AppColors.muted);
  static TextStyle get button => AppFonts.inter(size: 14, weight: FontWeight.w600);
}

/// Colors of a status (pill foreground/background, avatar).
class StatusColors {
  const StatusColors(this.fg, this.bg, this.onFg);
  final Color fg; // accent color (text on dark, pill background)
  final Color bg; // soft background (avatars)
  final Color onFg; // text drawn on [fg]

  static StatusColors of(AgentStatus s) => switch (s) {
    AgentStatus.waiting => StatusColors(AppColors.waiting, AppColors.waitingBg, AppColors.onWaiting),
    AgentStatus.working || AgentStatus.starting => StatusColors(AppColors.working, AppColors.workingBg, AppColors.onWorking),
    AgentStatus.exited => StatusColors(AppColors.faint, AppColors.raised, AppColors.text),
    _ => StatusColors(AppColors.muted, AppColors.raised, AppColors.bg),
  };
}

/// Spanish label of a status.
String statusLabel(AgentStatus s) => switch (s) {
  AgentStatus.waiting => 'Esperando',
  AgentStatus.working => 'Trabajando',
  AgentStatus.starting => 'Arrancando',
  AgentStatus.idle => 'Listo',
  AgentStatus.exited => 'Terminada',
  AgentStatus.unknown => 'Desconocido',
};

/// Builds the Material theme from [palette] (default: the active one).
ThemeData buildAppTheme([AppPalette? palette]) {
  final p = palette ?? AppColors.palette;
  final dark = p.brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accent,
    onPrimary: p.bg,
    secondary: p.accentLight,
    onSecondary: p.bg,
    surface: p.surface,
    onSurface: p.text,
    error: p.danger,
    onError: dark ? p.bg : Color(0xFFFFFFFF),
    outline: p.border,
  );
  final base = ThemeData(useMaterial3: true, brightness: p.brightness, colorScheme: scheme);
  final family = AppFonts.inter().fontFamily;
  return base.copyWith(
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    dividerColor: p.divider,
    textTheme: base.textTheme.apply(fontFamily: family, bodyColor: p.text, displayColor: p.text),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.raised2,
      contentTextStyle: TextStyle(fontSize: 14, fontFamily: family, color: p.text),
      behavior: SnackBarBehavior.floating,
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.surface, modalBackgroundColor: p.surface),
    dialogTheme: DialogThemeData(backgroundColor: p.surface),
    textSelectionTheme: TextSelectionThemeData(cursorColor: p.accent),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : Colors.transparent),
      checkColor: WidgetStatePropertyAll(p.bg),
      side: BorderSide(color: p.faint, width: 2),
    ),
  );
}
