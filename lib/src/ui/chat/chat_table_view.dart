// A parsed chat table as a real table widget: bold header on a raised
// background, palette borders, wrapping cells and horizontal scroll.

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../theme.dart';
import '../widgets/common.dart';
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
