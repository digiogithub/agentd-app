// Dark theme, palette and text styles of the validated mockups.

import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';

import '../core/contracts.dart';
import 'providers.dart' show ChatFont, DarkScheme, LightScheme, ThemeChoice;

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
    this.brightness = Brightness.dark,
  });

  /// A palette from the few colors a scheme defines; the tinted backgrounds
  /// and borders of the states are mixed from them.
  factory AppPalette.scheme({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color raised,
    required Color raised2,
    required Color border,
    required Color navBg,
    required Color terminalBg,
    required Color text,
    required Color secondary,
    required Color muted,
    required Color faint,
    required Color accent,
    required Color waiting,
    required Color working,
    required Color success,
    required Color danger,
  }) {
    Color mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
    final dark = brightness == Brightness.dark;
    final on = dark ? bg : const Color(0xFFFFFFFF);
    return AppPalette(
      brightness: brightness,
      bg: bg,
      surface: surface,
      raised: raised,
      raised2: raised2,
      border: border,
      divider: raised,
      navBg: navBg,
      terminalBg: terminalBg,
      text: text,
      secondary: secondary,
      muted: muted,
      faint: faint,
      accent: accent,
      accentBg: mix(surface, accent, dark ? 0.16 : 0.12),
      accentLight: mix(accent, text, 0.35),
      waiting: waiting,
      waitingBg: mix(surface, waiting, dark ? 0.14 : 0.12),
      waitingBorder: mix(surface, waiting, dark ? 0.24 : 0.3),
      questionBg: mix(surface, waiting, dark ? 0.06 : 0.05),
      questionBorder: mix(surface, waiting, 0.45),
      onWaiting: on,
      working: working,
      workingBg: mix(surface, working, dark ? 0.15 : 0.12),
      onWorking: on,
      success: success,
      successBg: mix(surface, success, dark ? 0.14 : 0.12),
      successText: dark ? mix(success, text, 0.3) : mix(success, const Color(0xFF000000), 0.25),
      danger: danger,
      dangerBg: mix(surface, danger, dark ? 0.12 : 0.1),
      dangerBorder: mix(surface, danger, 0.35),
    );
  }

  final Brightness brightness;

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
    brightness: Brightness.light,
  );

  /// Catppuccin Mocha.
  static final mocha = AppPalette.scheme(
    brightness: Brightness.dark,
    bg: const Color(0xFF181825),
    surface: const Color(0xFF1E1E2E),
    raised: const Color(0xFF313244),
    raised2: const Color(0xFF45475A),
    border: const Color(0xFF3A3B50),
    navBg: const Color(0xFF11111B),
    terminalBg: const Color(0xFF11111B),
    text: const Color(0xFFCDD6F4),
    secondary: const Color(0xFFBAC2DE),
    muted: const Color(0xFFA6ADC8),
    faint: const Color(0xFF7F849C),
    accent: const Color(0xFFB4BEFE),
    waiting: const Color(0xFFFAB387),
    working: const Color(0xFF89B4FA),
    success: const Color(0xFFA6E3A1),
    danger: const Color(0xFFF38BA8),
  );

  /// Pure black (OLED screens light no pixel for it).
  static final amoled = AppPalette.scheme(
    brightness: Brightness.dark,
    bg: const Color(0xFF000000),
    surface: const Color(0xFF0B0B0C),
    raised: const Color(0xFF17171A),
    raised2: const Color(0xFF212125),
    border: const Color(0xFF26262B),
    navBg: const Color(0xFF000000),
    terminalBg: const Color(0xFF000000),
    text: const Color(0xFFE8EAED),
    secondary: const Color(0xFFC8CCD1),
    muted: const Color(0xFF9AA0A6),
    faint: const Color(0xFF6B7075),
    accent: const Color(0xFF9DB4FF),
    waiting: const Color(0xFFF0A04B),
    working: const Color(0xFF58A6FF),
    success: const Color(0xFF3FB950),
    danger: const Color(0xFFFF9B9B),
  );

  /// Solarized dark (Ethan Schoonover), text one step brighter.
  static final solarizedDark = AppPalette.scheme(
    brightness: Brightness.dark,
    bg: const Color(0xFF002B36),
    surface: const Color(0xFF073642),
    raised: const Color(0xFF0D404D),
    raised2: const Color(0xFF154B59),
    border: const Color(0xFF1B4E5B),
    navBg: const Color(0xFF00252F),
    terminalBg: const Color(0xFF00212B),
    text: const Color(0xFFEEE8D5),
    secondary: const Color(0xFFBFC6C4),
    muted: const Color(0xFF93A1A1),
    faint: const Color(0xFF657B83),
    accent: const Color(0xFF268BD2),
    waiting: const Color(0xFFCB4B16),
    working: const Color(0xFF2AA198),
    success: const Color(0xFF859900),
    danger: const Color(0xFFDC322F),
  );

  /// Nord (Arctic Ice Studio).
  static final nord = AppPalette.scheme(
    brightness: Brightness.dark,
    bg: const Color(0xFF2E3440),
    surface: const Color(0xFF3B4252),
    raised: const Color(0xFF434C5E),
    raised2: const Color(0xFF4C566A),
    border: const Color(0xFF4C566A),
    navBg: const Color(0xFF2A2F3A),
    terminalBg: const Color(0xFF242933),
    text: const Color(0xFFECEFF4),
    secondary: const Color(0xFFD8DEE9),
    muted: const Color(0xFFAEB6C4),
    faint: const Color(0xFF7F899B),
    accent: const Color(0xFF88C0D0),
    waiting: const Color(0xFFD08770),
    working: const Color(0xFF81A1C1),
    success: const Color(0xFFA3BE8C),
    danger: const Color(0xFFBF616A),
  );

  /// Gruvbox dark, hard contrast (Pavel Pertsev).
  static final gruvbox = AppPalette.scheme(
    brightness: Brightness.dark,
    bg: const Color(0xFF1D2021),
    surface: const Color(0xFF282828),
    raised: const Color(0xFF3C3836),
    raised2: const Color(0xFF504945),
    border: const Color(0xFF45403D),
    navBg: const Color(0xFF1D2021),
    terminalBg: const Color(0xFF1D2021),
    text: const Color(0xFFEBDBB2),
    secondary: const Color(0xFFD5C4A1),
    muted: const Color(0xFFBDAE93),
    faint: const Color(0xFF928374),
    accent: const Color(0xFF83A598),
    waiting: const Color(0xFFFE8019),
    working: const Color(0xFF8EC07C),
    success: const Color(0xFFB8BB26),
    danger: const Color(0xFFFB4934),
  );

  /// Dracula.
  static final dracula = AppPalette.scheme(
    brightness: Brightness.dark,
    bg: const Color(0xFF21222C),
    surface: const Color(0xFF282A36),
    raised: const Color(0xFF343746),
    raised2: const Color(0xFF44475A),
    border: const Color(0xFF3E4152),
    navBg: const Color(0xFF1E1F29),
    terminalBg: const Color(0xFF191A21),
    text: const Color(0xFFF8F8F2),
    secondary: const Color(0xFFE2E2DC),
    muted: const Color(0xFFB0B3C6),
    faint: const Color(0xFF6272A4),
    accent: const Color(0xFFBD93F9),
    waiting: const Color(0xFFFFB86C),
    working: const Color(0xFF8BE9FD),
    success: const Color(0xFF50FA7B),
    danger: const Color(0xFFFF5555),
  );

  /// Cream paper with ink-brown text (sepia reading mode).
  static final cream = AppPalette.scheme(
    brightness: Brightness.light,
    bg: const Color(0xFFF4ECD8),
    surface: const Color(0xFFFBF6E9),
    raised: const Color(0xFFEFE5CD),
    raised2: const Color(0xFFE6DABE),
    border: const Color(0xFFDDD0B0),
    navBg: const Color(0xFFFBF6E9),
    terminalBg: const Color(0xFF2B2520),
    text: const Color(0xFF3B2F24),
    secondary: const Color(0xFF574738),
    muted: const Color(0xFF6F604E),
    faint: const Color(0xFF978670),
    accent: const Color(0xFF9A5B2F),
    waiting: const Color(0xFFB45F06),
    working: const Color(0xFF2F6F8F),
    success: const Color(0xFF4F7A28),
    danger: const Color(0xFFB23A2E),
  );

  /// Catppuccin Latte, text a step darker for contrast.
  static final latte = AppPalette.scheme(
    brightness: Brightness.light,
    bg: const Color(0xFFE6E9EF),
    surface: const Color(0xFFEFF1F5),
    raised: const Color(0xFFDCE0E8),
    raised2: const Color(0xFFCCD0DA),
    border: const Color(0xFFCCD0DA),
    navBg: const Color(0xFFEFF1F5),
    terminalBg: const Color(0xFF1E1E2E),
    text: const Color(0xFF363A4F),
    secondary: const Color(0xFF4C4F69),
    muted: const Color(0xFF575A72),
    faint: const Color(0xFF8C8FA1),
    accent: const Color(0xFF1E66F5),
    waiting: const Color(0xFFFE640B),
    working: const Color(0xFF209FB5),
    success: const Color(0xFF40A02B),
    danger: const Color(0xFFD20F39),
  );

  /// Solarized light, secondary text a step darker for contrast.
  static final solarizedLight = AppPalette.scheme(
    brightness: Brightness.light,
    bg: const Color(0xFFF3EDDA),
    surface: const Color(0xFFFDF6E3),
    raised: const Color(0xFFEEE8D5),
    raised2: const Color(0xFFE4DDC8),
    border: const Color(0xFFDAD3BD),
    navBg: const Color(0xFFFDF6E3),
    terminalBg: const Color(0xFF002B36),
    text: const Color(0xFF073642),
    secondary: const Color(0xFF3F555C),
    muted: const Color(0xFF52666D),
    faint: const Color(0xFF93A1A1),
    accent: const Color(0xFF268BD2),
    waiting: const Color(0xFFCB4B16),
    working: const Color(0xFF2AA198),
    success: const Color(0xFF859900),
    danger: const Color(0xFFDC322F),
  );

  static AppPalette ofDark(DarkScheme s) => switch (s) {
    DarkScheme.standard => dark,
    DarkScheme.mocha => mocha,
    DarkScheme.amoled => amoled,
    DarkScheme.solarized => solarizedDark,
    DarkScheme.nord => nord,
    DarkScheme.gruvbox => gruvbox,
    DarkScheme.dracula => dracula,
  };

  static AppPalette ofLight(LightScheme s) => switch (s) {
    LightScheme.standard => light,
    LightScheme.cream => cream,
    LightScheme.latte => latte,
    LightScheme.solarized => solarizedLight,
  };

  static AppPalette of(Brightness b) => b == Brightness.dark ? dark : light;

  /// Palette for a user choice, given the platform brightness (for `system`)
  /// and the scheme chosen for each brightness.
  static AppPalette resolve(ThemeChoice choice, Brightness platform, {DarkScheme darkScheme = DarkScheme.standard, LightScheme lightScheme = LightScheme.standard}) {
    final b = switch (choice) {
      ThemeChoice.dark => Brightness.dark,
      ThemeChoice.light => Brightness.light,
      ThemeChoice.system => platform,
    };
    return b == Brightness.dark ? ofDark(darkScheme) : ofLight(lightScheme);
  }
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

  /// Chat prose in the chosen [ChatFont]: Inter, Noto Serif (the system
  /// serif without runtime fetching) or JetBrains Mono.
  static TextStyle chat(ChatFont font, {required double size, FontWeight weight = FontWeight.w400, Color? color, double? height}) {
    switch (font) {
      case ChatFont.sans:
        return inter(size: size, weight: weight, color: color, height: height);
      case ChatFont.mono:
        return mono(size: size, weight: weight, color: color ?? AppColors.text, height: height);
      case ChatFont.serif:
        final base = TextStyle(fontSize: size, fontWeight: weight, color: color ?? AppColors.text, height: height);
        return _google ? GoogleFonts.notoSerif(textStyle: base) : base.copyWith(fontFamily: 'serif');
      case ChatFont.legible:
        final base = TextStyle(fontSize: size, fontWeight: weight, color: color ?? AppColors.text, height: height);
        return _google ? GoogleFonts.atkinsonHyperlegibleNext(textStyle: base) : base.copyWith(fontFamily: 'Atkinson Hyperlegible Next');
      case ChatFont.reading:
        final base = TextStyle(fontSize: size, fontWeight: weight, color: color ?? AppColors.text, height: height);
        return _google ? GoogleFonts.literata(textStyle: base) : base.copyWith(fontFamily: 'Literata', fontFamilyFallback: const ['serif']);
    }
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
