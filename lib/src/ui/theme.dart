// Dark theme, palette and text styles of the validated mockups.

import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';

import '../core/contracts.dart';

/// Palette of the mockups. Names follow their role, not their hue.
abstract final class AppColors {
  static const bg = Color(0xFF0D1117);
  static const surface = Color(0xFF161B22);
  static const raised = Color(0xFF1F2630);
  static const raised2 = Color(0xFF262E3A);
  static const border = Color(0xFF2A3340);
  static const divider = Color(0xFF1F2630);
  static const navBg = Color(0xFF10151C);
  static const terminalBg = Color(0xFF07090D);

  static const text = Color(0xFFE6EDF3);
  static const secondary = Color(0xFFC9D4DF);
  static const muted = Color(0xFF9AA7B4);
  static const faint = Color(0xFF6E7B88);

  static const accent = Color(0xFF9DB4FF);
  static const accentBg = Color(0xFF1B2233);
  static const accentLight = Color(0xFFC3D1FF);

  static const waiting = Color(0xFFF0A04B);
  static const waitingBg = Color(0xFF2B2116);
  static const waitingBorder = Color(0xFF3A2E1E);
  static const questionBg = Color(0xFF1A1610);
  static const questionBorder = Color(0xFF5A4220);
  static const onWaiting = Color(0xFF1A1206);

  static const working = Color(0xFF58A6FF);
  static const workingBg = Color(0xFF13233A);
  static const onWorking = Color(0xFF08172B);

  static const success = Color(0xFF3FB950);
  static const successBg = Color(0xFF12261A);
  static const successText = Color(0xFF7EE2A0);

  static const danger = Color(0xFFFF9B9B);
  static const dangerBg = Color(0xFF2A1515);
  static const dangerBorder = Color(0xFF5A2A2A);
}

/// Fonts: Inter for UI, JetBrains Mono for code. Google Fonts is used only
/// when runtime fetching is allowed (tests turn it off): otherwise the plain
/// family names are used and the platform falls back.
abstract final class AppFonts {
  static bool get _google => GoogleFonts.config.allowRuntimeFetching;

  static TextStyle inter({double size = 14, FontWeight weight = FontWeight.w400, Color color = AppColors.text, double? height, double? letterSpacing}) {
    final base = TextStyle(fontSize: size, fontWeight: weight, color: color, height: height, letterSpacing: letterSpacing);
    return _google ? GoogleFonts.inter(textStyle: base) : base.copyWith(fontFamily: 'Inter');
  }

  static TextStyle mono({double size = 13, FontWeight weight = FontWeight.w400, Color color = AppColors.secondary, double? height}) {
    final base = TextStyle(fontSize: size, fontWeight: weight, color: color, height: height);
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
    AgentStatus.waiting => const StatusColors(AppColors.waiting, AppColors.waitingBg, AppColors.onWaiting),
    AgentStatus.working || AgentStatus.starting => const StatusColors(AppColors.working, AppColors.workingBg, AppColors.onWorking),
    AgentStatus.exited => const StatusColors(AppColors.faint, AppColors.raised, AppColors.text),
    _ => const StatusColors(AppColors.muted, AppColors.raised, AppColors.bg),
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

ThemeData buildAppTheme() {
  final scheme = const ColorScheme.dark(
    primary: AppColors.accent,
    onPrimary: AppColors.bg,
    secondary: AppColors.accentLight,
    onSecondary: AppColors.bg,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    error: AppColors.danger,
    onError: AppColors.bg,
    outline: AppColors.border,
  );
  final base = ThemeData(useMaterial3: true, brightness: Brightness.dark, colorScheme: scheme);
  final family = AppFonts.inter().fontFamily;
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
    dividerColor: AppColors.divider,
    textTheme: base.textTheme.apply(fontFamily: family, bodyColor: AppColors.text, displayColor: AppColors.text),
    snackBarTheme: SnackBarThemeData(backgroundColor: AppColors.raised2, contentTextStyle: AppFonts.inter(size: 14), behavior: SnackBarBehavior.floating),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: AppColors.surface, modalBackgroundColor: AppColors.surface),
    dialogTheme: const DialogThemeData(backgroundColor: AppColors.surface),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: AppColors.accent),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.accent : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(AppColors.bg),
      side: const BorderSide(color: AppColors.faint, width: 2),
    ),
  );
}
