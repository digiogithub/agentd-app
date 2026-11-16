// Chat text with `inline code` and clickable http(s) links.

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import '../widgets/common.dart';
import 'links.dart';

class LinkifiedText extends ConsumerStatefulWidget {
  const LinkifiedText(
    this.text, {
    super.key,
    required this.style,
    this.codeColor,
    this.codeSize,
  });
  final String text;
  final TextStyle style;
  final Color? codeColor;
  final double? codeSize;

  @override
  ConsumerState<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends ConsumerState<LinkifiedText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    var ok = false;
    try {
      ok = await ref.read(urlLauncherProvider)(uri);
    } catch (_) {}
    if (!ok && mounted) showToast(context, 'No se pudo abrir el enlace');
  }

  List<InlineSpan> _spans(String s, TextStyle? base) {
    final out = <InlineSpan>[];
    var pos = 0;
    for (final m in findUrls(s)) {
      if (m.start > pos) {
        out.add(TextSpan(text: s.substring(pos, m.start), style: base));
      }
      final r = TapGestureRecognizer()..onTap = () => _open(m.url);
      _recognizers.add(r);
      out.add(
        TextSpan(
          text: m.url,
          recognizer: r,
          style: (base ?? const TextStyle()).copyWith(
            color: AppColors.accent,
            decoration: TextDecoration.underline,
            decorationColor: AppColors.accent,
          ),
        ),
      );
      pos = m.end;
    }
    if (pos < s.length) out.add(TextSpan(text: s.substring(pos), style: base));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final style = widget.style;
    final parts = widget.text.split('`');
    final spans = <InlineSpan>[];
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      final code = i.isOdd && i < parts.length - 1;
      spans.addAll(
        _spans(
          parts[i],
          code
              ? AppFonts.mono(
                  size: widget.codeSize ?? (style.fontSize ?? 14) - 1.5,
                  color: widget.codeColor ?? style.color ?? AppColors.text,
                )
              : null,
        ),
      );
    }
    return Text.rich(TextSpan(style: style, children: spans));
  }
}
