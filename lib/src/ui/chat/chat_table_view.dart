// A parsed chat table as a real table widget: bold header on a raised
// background, palette borders, wrapping cells and horizontal scroll.

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import '../widgets/common.dart';
import 'code_text.dart';
import 'linkified_text.dart';
import 'table_parser.dart';

const double kTableMinColumn = 80;
const double kTableMaxColumn = 260;
const _cellPad = EdgeInsets.symmetric(horizontal: 10, vertical: 8);

class ChatTableView extends StatelessWidget {
  const ChatTableView({super.key, required this.table});
  final ChatTable table;

  TextStyle get _cell => AppFonts.inter(size: 13, height: 1.35);
  TextStyle get _head =>
      AppFonts.inter(size: 13, weight: FontWeight.w700, height: 1.35);

  List<double> _widths(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final dir = Directionality.of(context);
    double measure(String s, TextStyle st) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: st),
        textDirection: dir,
        textScaler: scaler,
      )..layout();
      return tp.width;
    }

    return [
      for (var c = 0; c < table.columns; c++)
        () {
          var w = 0.0;
          if (table.header != null) w = measure(table.header![c], _head);
          for (final r in table.rows) {
            w = math.max(w, measure(r[c], _cell));
          }
          return (w + _cellPad.horizontal + 2)
              .clamp(kTableMinColumn, kTableMaxColumn)
              .toDouble();
        }(),
    ];
  }

  void _copy(BuildContext context, String text, String toast) {
    Clipboard.setData(ClipboardData(text: text));
    showToast(context, toast);
  }

  Widget _cellBox(
    BuildContext context,
    String text,
    TextStyle style, {
    Color? bg,
  }) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPress: () => _copy(context, text, 'Celda copiada'),
    child: Container(
      color: bg,
      padding: _cellPad,
      alignment: Alignment.topLeft,
      child: LinkifiedText(text, style: style),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (table.columns == 0) return const SizedBox.shrink();
    final widths = _widths(context);
    final t = Table(
      key: const ValueKey('chat-table'),
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      columnWidths: {
        for (var i = 0; i < widths.length; i++) i: FixedColumnWidth(widths[i]),
      },
      border: TableBorder.all(color: AppColors.border, width: 1),
      children: [
        if (table.header != null)
          TableRow(
            children: [
              for (final h in table.header!)
                _cellBox(context, h, _head, bg: AppColors.raised),
            ],
          ),
        for (final r in table.rows)
          TableRow(children: [for (final c in r) _cellBox(context, c, _cell)]),
      ],
    );
    return Semantics(
      container: true,
      label: 'Tabla de ${table.rows.length} filas y ${table.columns} columnas',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: t),
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              key: const ValueKey('copy-table'),
              onTap: () => _copy(context, table.toText(), 'Tabla copiada'),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.copy, size: 14, color: AppColors.muted),
                      const SizedBox(width: 6),
                      Text('Copiar tabla', style: AppText.caption),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A code block of the agent: monospace, scrolls sideways, with a button
/// that copies the whole block and one that shows it as normal, wrapped text
/// (for prose the daemon took for code) and back.
class ChatCodeBlock extends StatefulWidget {
  const ChatCodeBlock({super.key, required this.code, this.fontSize = 12.5, this.textStyle});
  final String code;
  final double fontSize;

  /// Style of the text mode (the chat font).
  final TextStyle? textStyle;

  @override
  State<ChatCodeBlock> createState() => _ChatCodeBlockState();
}

class _ChatCodeBlockState extends State<ChatCodeBlock> {
  // Used when no [CodeBlockModes] is above (the block alone).
  bool _local = false;

  @override
  Widget build(BuildContext context) {
    final code = widget.code;
    final modes = CodeBlockModes.maybeOf(context);
    final id = codeBlockKey(code);
    final asText = modes?.contains(id) ?? _local;
    void toggle() => setState(() {
      if (modes == null) {
        _local = !_local;
      } else if (!modes.remove(id)) {
        modes.add(id);
      }
    });
    return Semantics(
      container: true,
      label: asText ? 'Bloque de código como texto' : 'Bloque de código',
      child: Container(
        key: const ValueKey('code-block'),
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        // Buttons on a bar above the block, so the text gets the full width
        // (side buttons left a narrow column for wrapped text).
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The buttons are not part of a text selection.
            SelectionContainer.disabled(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  RoundIconButton(
                    key: const ValueKey('toggle-code'),
                    icon: asText ? Icons.code : Icons.wrap_text,
                    label: asText ? 'Mostrar como código' : 'Mostrar como texto',
                    fg: AppColors.muted,
                    iconSize: 16,
                    onPressed: toggle,
                  ),
                  RoundIconButton(
                    key: const ValueKey('copy-code'),
                    icon: Icons.copy,
                    label: 'Copiar código',
                    fg: AppColors.muted,
                    iconSize: 16,
                    onPressed: () {
                      // Always the block as the agent wrote it.
                      Clipboard.setData(ClipboardData(text: code));
                      showToast(context, 'Código copiado');
                    },
                  ),
                ],
              ),
            ),
            asText
                ? Padding(
                    key: const ValueKey('code-as-text'),
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: LinkifiedText(
                      codeAsProse(code),
                      style: widget.textStyle ?? AppFonts.inter(size: widget.fontSize + 2, color: AppColors.text, height: 1.5),
                      inlineCode: false,
                    ),
                  )
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Text(code, softWrap: false, style: AppFonts.mono(size: widget.fontSize, color: AppColors.text, height: 1.45)),
                  ),
          ],
        ),
      ),
    );
  }
}
