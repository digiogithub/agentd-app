// Chat markup (agentd view `markup: true`): the CommonMark subset the daemon
// builds from terminal styles — `### heading`, `**bold**`, `` `code` ``,
// `- ` / `1. ` lists, backslash escapes — drawn with clickable links.

import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import '../widgets/common.dart';
import 'links.dart';

/// A block of chat markup.
sealed class MarkupBlock {
  const MarkupBlock();
}

class HeadingBlock extends MarkupBlock {
  const HeadingBlock(this.text);
  final String text;
}

class ParagraphBlock extends MarkupBlock {
  const ParagraphBlock(this.text);
  final String text;
}

class ListItemBlock extends MarkupBlock {
  const ListItemBlock(this.marker, this.text, {this.depth = 0});
  final String marker; // "•" or "1."
  final String text;
  final int depth;
}

final RegExp _bullet = RegExp(r'^(\s*)([-•*+])\s+(.*)$');
final RegExp _ordered = RegExp(r'^(\s*)(\d{1,3}[.)])\s+(.*)$');

/// Cuts [src] into blocks: a "### " line is a heading, list lines are items
/// (depth from their indentation), consecutive other lines one paragraph,
/// blank lines separate paragraphs.
List<MarkupBlock> parseMarkupBlocks(String src) {
  final out = <MarkupBlock>[];
  final para = <String>[];
  void flush() {
    if (para.isNotEmpty) out.add(ParagraphBlock(para.join('\n')));
    para.clear();
  }

  for (final line in src.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) {
      flush();
      continue;
    }
    final h = RegExp(r'^#{1,6} (.*)$').firstMatch(t);
    if (h != null) {
      flush();
      out.add(HeadingBlock(h.group(1)!));
      continue;
    }
    final b = _bullet.firstMatch(line);
    final o = b == null ? _ordered.firstMatch(line) : null;
    final m = b ?? o;
    if (m != null) {
      flush();
      out.add(
        ListItemBlock(
          b != null ? '•' : m.group(2)!,
          m.group(3)!,
          depth: (m.group(1)!.length ~/ 2).clamp(0, 3),
        ),
      );
      continue;
    }
    para.add(t);
  }
  flush();
  return out;
}

/// An inline run of chat markup.
class MarkupRun {
  const MarkupRun(this.text, {this.bold = false, this.code = false});
  final String text;
  final bool bold;
  final bool code;
}

/// Inline markup: `\x` escapes, `**bold**`, `` `code` `` (raw content).
List<MarkupRun> parseMarkupInline(String s) {
  final out = <MarkupRun>[];
  final buf = StringBuffer();
  var bold = false;
  void emit() {
    if (buf.isNotEmpty) out.add(MarkupRun(buf.toString(), bold: bold));
    buf.clear();
  }

  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length && _punct.contains(s[i + 1])) {
      buf.write(s[i + 1]);
      i += 2;
    } else if (c == '*' && i + 1 < s.length && s[i + 1] == '*') {
      emit();
      bold = !bold;
      i += 2;
    } else if (c == '`') {
      final end = s.indexOf('`', i + 1);
      if (end < 0) {
        buf.write(c);
        i++;
        continue;
      }
      emit();
      out.add(MarkupRun(s.substring(i + 1, end), bold: bold, code: true));
      i = end + 1;
    } else {
      buf.write(c);
      i++;
    }
  }
  emit();
  return out;
}

const _punct = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

/// Plain text of chat markup (table cells, copying).
String unmarkup(String s) {
  final t = s.startsWith('### ') ? s.substring(4) : s;
  return parseMarkupInline(t).map((r) => r.text).join();
}

/// Chat markup drawn as headings, paragraphs and list items.
class MarkupText extends ConsumerStatefulWidget {
  const MarkupText(
    this.markup, {
    super.key,
    required this.style,
    this.codeColor,
  });
  final String markup;

  /// Body style (font, size, colour, line height).
  final TextStyle style;
  final Color? codeColor;

  @override
  ConsumerState<MarkupText> createState() => _MarkupTextState();
}

class _MarkupTextState extends ConsumerState<MarkupText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
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

  List<InlineSpan> _inline(String s, TextStyle base) {
    final out = <InlineSpan>[];
    final size = base.fontSize ?? 14.5;
    for (final r in parseMarkupInline(s)) {
      if (r.code) {
        out.add(
          TextSpan(
            text: r.text,
            style:
                AppFonts.mono(
                  size: size - 1.5,
                  color: widget.codeColor ?? AppColors.accentLight,
                ).copyWith(
                  backgroundColor: AppColors.surface,
                  fontWeight: r.bold ? FontWeight.w600 : null,
                ),
          ),
        );
        continue;
      }
      final style = r.bold ? base.copyWith(fontWeight: FontWeight.w700) : base;
      var pos = 0;
      for (final m in findUrls(r.text)) {
        if (m.start > pos) {
          out.add(TextSpan(text: r.text.substring(pos, m.start), style: style));
        }
        final rec = TapGestureRecognizer()..onTap = () => _open(m.url);
        _recognizers.add(rec);
        out.add(
          TextSpan(
            text: m.url,
            recognizer: rec,
            style: style.copyWith(
              color: AppColors.accent,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.accent,
            ),
          ),
        );
        pos = m.end;
      }
      if (pos < r.text.length) {
        out.add(TextSpan(text: r.text.substring(pos), style: style));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final base = widget.style;
    final size = base.fontSize ?? 14.5;
    final blocks = parseMarkupBlocks(widget.markup);
    final children = <Widget>[];
    for (final (i, b) in blocks.indexed) {
      final gap = i == 0
          ? 0.0
          : (b is HeadingBlock
                ? size * 1.1
                : (b is ListItemBlock && blocks[i - 1] is ListItemBlock
                      ? size * 0.3
                      : size * 0.7));
      if (gap > 0) children.add(SizedBox(height: gap));
      switch (b) {
        case HeadingBlock():
          final hs = base.copyWith(
            fontSize: size * 1.35,
            fontWeight: FontWeight.w700,
            height: 1.25,
          );
          children.add(
            Semantics(
              header: true,
              child: Text.rich(TextSpan(children: _inline(b.text, hs))),
            ),
          );
        case ParagraphBlock():
          children.add(Text.rich(TextSpan(children: _inline(b.text, base))));
        case ListItemBlock():
          children.add(
            Padding(
              padding: EdgeInsets.only(left: b.depth * size * 1.2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: size * 1.4,
                    child: Text(
                      b.marker,
                      style: base.copyWith(color: AppColors.muted),
                    ),
                  ),
                  Expanded(
                    child: Text.rich(TextSpan(children: _inline(b.text, base))),
                  ),
                ],
              ),
            ),
          );
      }
    }
    if (children.length == 1) return children.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
