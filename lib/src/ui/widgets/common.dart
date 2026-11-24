// Shared building blocks of the screens: labels, pills, cards, buttons,
// switches, segmented controls and text fields drawn as in the mockups.

import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../theme.dart';

/// Uppercase section header ("NECESITAN RESPUESTA · 2").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.color, this.padding = EdgeInsets.zero});
  final String text;
  final Color? color;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Semantics(
      header: true,
      child: Text(text.toUpperCase(), style: AppText.sectionLabel.copyWith(color: color ?? AppColors.muted)),
    ),
  );
}

/// Small rounded tag (host capabilities, detected tools).
class TagChip extends StatelessWidget {
  const TagChip(this.text, {super.key, this.bg, this.fg});
  final String text;
  final Color? bg;
  final Color? fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: bg ?? AppColors.raised, borderRadius: BorderRadius.circular(999)),
    child: Text(text, style: AppFonts.inter(size: 12, color: fg ?? AppColors.secondary)),
  );
}

/// Filled status pill ("Esperando", "Permiso", "En cola").
class StatusPill extends StatelessWidget {
  const StatusPill(this.text, {super.key, required this.bg, required this.fg});

  factory StatusPill.status(AgentStatus s, {Key? key}) {
    final c = StatusColors.of(s);
    final idle = s == AgentStatus.idle || s == AgentStatus.exited || s == AgentStatus.unknown;
    return StatusPill(statusLabel(s), key: key, bg: idle ? AppColors.raised : c.fg, fg: idle ? AppColors.secondary : c.onFg);
  }

  final String text;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
    child: Text(
      text,
      style: AppFonts.inter(size: 11, weight: FontWeight.w600, color: fg),
    ),
  );
}

/// Rounded square with a letter or an icon (session avatars).
class Avatar extends StatelessWidget {
  const Avatar({super.key, this.letter, this.icon, required this.bg, required this.fg});
  final String? letter;
  final IconData? icon;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: icon != null
          ? Icon(icon, size: 18, color: fg)
          : Text(
              letter ?? '',
              style: AppFonts.inter(size: 14, weight: FontWeight.w700, color: fg),
            ),
    ),
  );
}

/// Surface card with a border; tappable when [onTap] is set.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(14),
    this.radius = 18,
    this.color,
    this.borderColor,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final double radius;
  final Color? color;
  final Color? borderColor;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: borderColor ?? AppColors.border),
    );
    final content = Padding(padding: padding, child: child);
    return Semantics(
      container: true,
      label: semanticLabel,
      button: onTap != null,
      child: Material(
        color: color ?? AppColors.surface,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? content : InkWell(onTap: onTap, child: content),
      ),
    );
  }
}

enum AppButtonStyle { accent, light, outline, waiting, danger, soft }

/// Text button with the mockup styles (min height 44).
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.style = AppButtonStyle.accent,
    this.height = 44,
    this.radius = 12,
    this.expand = false,
    this.icon,
    this.fontSize = 14,
    this.bold = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 14),
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonStyle style;
  final double height;
  final double radius;
  final bool expand;
  final IconData? icon;
  final double fontSize;
  final bool bold;
  final EdgeInsets padding;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (style) {
      AppButtonStyle.accent => (AppColors.accent, AppColors.bg, null),
      AppButtonStyle.light => (AppColors.text, AppColors.bg, null),
      AppButtonStyle.outline => (Colors.transparent, AppColors.text, AppColors.border),
      AppButtonStyle.waiting => (AppColors.waiting, AppColors.onWaiting, null),
      AppButtonStyle.danger => (AppColors.dangerBg, AppColors.danger, AppColors.dangerBorder),
      AppButtonStyle.soft => (AppColors.accentBg, AppColors.accentLight, AppColors.accent),
    };
    final disabled = onPressed == null;
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.inter(size: fontSize, weight: bold ? FontWeight.w700 : FontWeight.w600, color: fg),
          ),
        ),
      ],
    );
    return Semantics(
      container: true,
      button: true,
      enabled: !disabled,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Opacity(
        opacity: disabled ? 0.45 : 1,
        child: SizedBox(
          height: height < 44 ? 44 : height,
          width: expand ? double.infinity : null,
          child: Material(
            color: bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
              side: border == null ? BorderSide.none : BorderSide(color: border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Circular 44px icon button with a semantics label.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.bg = Colors.transparent,
    this.fg,
    this.border,
    this.size = 44,
    this.iconSize = 22,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color bg;
  final Color? fg;
  final Color? border;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: label,
    excludeSemantics: true,
    child: Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: bg,
          shape: CircleBorder(side: border == null ? BorderSide.none : BorderSide(color: border!)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Icon(icon, size: iconSize, color: fg ?? AppColors.text),
          ),
        ),
      ),
    ),
  );
}

/// The mockup switch: 52x32 track, 26px knob.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged, required this.label});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    toggled: value,
    label: label,
    button: true,
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 52,
          height: 32,
          padding: const EdgeInsets.all(3),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(color: value ? AppColors.accent : AppColors.border, borderRadius: BorderRadius.circular(16)),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(color: value ? AppColors.bg : AppColors.muted, borderRadius: BorderRadius.circular(13)),
          ),
        ),
      ),
    ),
  );
}

/// Row with a title, subtitle and an [AppSwitch].
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, this.subtitle, required this.value, required this.onChanged, this.divider = false});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool divider;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 60),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: divider
        ? BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.divider)),
          )
        : null,
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppFonts.inter(size: 14.5, weight: FontWeight.w500)),
              if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: AppText.caption)],
            ],
          ),
        ),
        const SizedBox(width: 12),
        AppSwitch(value: value, onChanged: onChanged, label: title),
      ],
    ),
  );
}

/// Segmented control (Chat/Terminal, agentd/zellij/tmux/SSH, theme).
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({super.key, required this.options, required this.value, required this.onChanged, this.height = 38, this.radio = false, this.enabled});
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final double height;

  /// Radio semantics instead of tab semantics.
  final bool radio;
  final bool Function(T)? enabled;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
    child: Row(
      children: [
        for (final (i, (v, label)) in options.indexed) ...[if (i > 0) const SizedBox(width: 4), Expanded(child: _segment(v, label))],
      ],
    ),
  );

  Widget _segment(T v, String label) {
    final on = v == value;
    final ok = enabled?.call(v) ?? true;
    return Semantics(
      container: true,
      selected: on,
      inMutuallyExclusiveGroup: radio,
      checked: radio ? on : null,
      button: true,
      enabled: ok,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: ok ? () => onChanged(v) : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: height < 36 ? 36 : height,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: on ? AppColors.raised2 : Colors.transparent, borderRadius: BorderRadius.circular(9)),
          child: Text(
            label,
            style: AppFonts.inter(
              size: 13,
              weight: on ? FontWeight.w600 : FontWeight.w500,
              color: !ok ? AppColors.faint : (on ? AppColors.text : AppColors.muted),
            ),
          ),
        ),
      ),
    );
  }
}

/// Outlined pill chip used for filters (34px, accent when selected).
class FilterPill extends StatelessWidget {
  const FilterPill({super.key, required this.label, required this.selected, required this.onTap, this.height = 34, this.radius = 17, this.mono = false});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double height;
  final double radius;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final style = mono
        ? AppFonts.mono(size: 13, color: selected ? AppColors.accentLight : AppColors.secondary)
        : AppFonts.inter(size: 13, weight: FontWeight.w500, color: selected ? AppColors.accentLight : AppColors.muted);
    return Semantics(
      container: true,
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Center(
            widthFactor: 1,
            child: Container(
              height: height,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected ? AppColors.accentBg : (mono ? AppColors.surface : Colors.transparent),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: selected ? AppColors.accent : AppColors.border),
              ),
              child: Center(widthFactor: 1, child: Text(label, style: style)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Selectable tile with an accent border when selected (agent grid, auth).
class SelectTile extends StatelessWidget {
  const SelectTile({super.key, required this.selected, required this.onTap, required this.child, this.minHeight = 56, this.semanticLabel, this.radio = false});
  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  final double minHeight;
  final String? semanticLabel;
  final bool radio;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    selected: selected,
    checked: radio ? selected : null,
    inMutuallyExclusiveGroup: radio,
    button: true,
    label: semanticLabel,
    child: Material(
      color: selected ? AppColors.accentBg : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? AppColors.accent : AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: minHeight),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: child),
        ),
      ),
    ),
  );
}

/// Text field drawn as the mockup inputs (46px, surface, 12 radius).
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.hint,
    this.mono = false,
    this.keyboardType,
    this.onSubmitted,
    this.obscure = false,
    this.focusNode,
    this.enabled = true,
    this.semanticLabel,
    this.radius = 12,
    this.textInputAction,
    this.onChanged,
    this.maxLines = 1,
  });

  final TextEditingController? controller;
  final String? hint;
  final bool mono;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;
  final bool obscure;
  final FocusNode? focusNode;
  final bool enabled;
  final String? semanticLabel;
  final double radius;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;

  /// More than 1: the field grows up to this many lines and keeps the line
  /// breaks of a pasted text.
  final int maxLines;

  static InputDecoration decoration({String? hint, bool mono = false, double radius = 12, EdgeInsets? padding}) {
    OutlineInputBorder b(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(radius),
      borderSide: BorderSide(color: c),
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: mono ? AppFonts.mono(size: 13, color: AppColors.faint) : AppFonts.inter(size: 14.5, color: AppColors.faint),
      filled: true,
      fillColor: AppColors.surface,
      isDense: true,
      contentPadding: padding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: b(AppColors.border),
      enabledBorder: b(AppColors.border),
      disabledBorder: b(AppColors.divider),
      focusedBorder: b(AppColors.accent),
    );
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    focusNode: focusNode,
    enabled: enabled,
    obscureText: obscure,
    minLines: 1,
    maxLines: maxLines,
    keyboardType: keyboardType,
    textInputAction: textInputAction,
    onSubmitted: onSubmitted,
    onChanged: onChanged,
    style: mono ? AppFonts.mono(size: 15, color: AppColors.text) : AppFonts.inter(size: 15),
    decoration: decoration(hint: hint, mono: mono, radius: radius).copyWith(semanticCounterText: semanticLabel),
  );
}

/// Labelled field ("Nombre" above the input).
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: AppFonts.inter(size: 13, color: AppColors.secondary)),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );
}

/// Top header of the bottom-nav screens: overline, big title, trailing.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({super.key, this.overline, required this.title, this.trailing, this.bottom});
  final String? overline;
  final String title;
  final Widget? trailing;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (overline != null) ...[Text(overline!, style: AppText.overline), const SizedBox(height: 2)],
                  Semantics(header: true, child: Text(title, style: AppText.screenTitle)),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
        if (bottom != null) ...[const SizedBox(height: 14), bottom!],
      ],
    ),
  );
}

/// Header of pushed routes: back/close button, title, optional subtitle.
class RouteHeader extends StatelessWidget {
  const RouteHeader({super.key, required this.title, this.subtitle, this.close = false, this.trailing = const [], this.titleStyle});
  final String title;
  final String? subtitle;
  final bool close;
  final List<Widget> trailing;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
    child: Row(
      children: [
        RoundIconButton(icon: close ? Icons.close : Icons.chevron_left, label: close ? 'Cerrar' : 'Volver', onPressed: () => Navigator.of(context).maybePop()),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(title, style: titleStyle ?? AppText.routeTitle, overflow: TextOverflow.ellipsis),
              ),
              if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: AppText.caption, overflow: TextOverflow.ellipsis)],
            ],
          ),
        ),
        ...trailing,
      ],
    ),
  );
}

/// Text where `backtick` spans are drawn in mono (agent messages, questions).
class InlineCodeText extends StatelessWidget {
  const InlineCodeText(this.text, {super.key, required this.style, this.codeColor, this.maxLines, this.codeSize});
  final String text;
  final TextStyle style;
  final Color? codeColor;
  final int? maxLines;
  final double? codeSize;

  @override
  Widget build(BuildContext context) {
    final parts = text.split('`');
    final spans = <InlineSpan>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      final code = i.isOdd && i < parts.length - 1;
      spans.add(
        TextSpan(
          text: parts[i],
          style: code ? AppFonts.mono(size: codeSize ?? (style.fontSize ?? 14) - 1.5, color: codeColor ?? style.color ?? AppColors.text) : null,
        ),
      );
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

/// Shows a short floating message.
void showToast(BuildContext context, String text) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(text)));
}

/// Extended floating action button of the mockups (52px, accent).
class AppFab extends StatelessWidget {
  const AppFab({super.key, required this.label, required this.onTap, this.icon = Icons.add});
  final String label;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: label,
    excludeSemantics: true,
    child: Material(
      color: AppColors.accent,
      elevation: 8,
      shadowColor: Colors.black,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 52,
          padding: const EdgeInsets.fromLTRB(16, 0, 20, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: AppColors.bg),
              const SizedBox(width: 8),
              Text(
                label,
                style: AppFonts.inter(size: 15, weight: FontWeight.w600, color: AppColors.bg),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
