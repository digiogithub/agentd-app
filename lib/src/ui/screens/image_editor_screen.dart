// Full-screen markup editor for an image before it is sent to an agent:
// pen, arrow, rectangle and text label over the picture.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../annotate/annotation_model.dart';
import '../annotate/annotation_painter.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// What the editor returns on "Listo": the flattened PNG and the model (to
/// reopen the editor on the original image with its marks).
class EditorResult {
  const EditorResult({required this.png, required this.model});
  final Uint8List png;
  final AnnotationModel model;
}

/// Opens the editor on [bytes]; null when cancelled.
Future<EditorResult?> openImageEditor(
  BuildContext context,
  Uint8List bytes, {
  AnnotationModel? model,
}) => Navigator.of(context).push<EditorResult>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => ImageEditorScreen(bytes: bytes, model: model),
  ),
);

class ImageEditorScreen extends StatefulWidget {
  const ImageEditorScreen({super.key, required this.bytes, this.model});

  /// The original image (any format the engine decodes).
  final Uint8List bytes;

  /// Marks to start from; the editor edits a copy.
  final AnnotationModel? model;

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  ui.Image? _image;
  AnnotationModel? _model;
  Object? _error;
  bool _saving = false;

  AnnotationTool _tool = AnnotationTool.pen;
  int _color = AnnotationColors.danger;
  StrokeWeight _weight = StrokeWeight.thin;

  final _repaint = ValueNotifier<int>(0);
  Mark? _draft;
  List<Pt> _penPoints = [];
  Pt? _dragStart;

  @override
  void initState() {
    super.initState();
    unawaited(_decode());
  }

  @override
  void dispose() {
    _image?.dispose();
    _repaint.dispose();
    super.dispose();
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      final img = frame.image;
      setState(() {
        _image = img;
        final m = widget.model;
        _model =
            m != null &&
                m.imageWidth == img.width &&
                m.imageHeight == img.height
            ? m.copy()
            : AnnotationModel(
                imageWidth: img.width.toDouble(),
                imageHeight: img.height.toDouble(),
              );
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _bump() => _repaint.value++;

  Mark? _build(Pt a, Pt b) {
    final m = _model!;
    final w = m.strokeWidth(_weight);
    return switch (_tool) {
      AnnotationTool.arrow => ArrowMark(
        from: a,
        to: b,
        color: _color,
        width: w,
      ),
      AnnotationTool.rect => RectMark(a: a, b: b, color: _color, width: w),
      _ => null,
    };
  }

  void _panStart(ImageViewport vp, Offset p) {
    if (_tool == AnnotationTool.text) return;
    final pt = vp.toImageClamped(p.dx, p.dy);
    _dragStart = pt;
    if (_tool == AnnotationTool.pen) {
      _penPoints = [pt];
      _draft = PenMark(
        points: _penPoints,
        color: _color,
        width: _model!.strokeWidth(_weight),
      );
    } else {
      _draft = _build(pt, pt);
    }
    _bump();
  }

  void _panUpdate(ImageViewport vp, Offset p) {
    final start = _dragStart;
    if (start == null) return;
    final pt = vp.toImageClamped(p.dx, p.dy);
    if (_tool == AnnotationTool.pen) {
      _penPoints = [..._penPoints, pt];
      _draft = PenMark(
        points: _penPoints,
        color: _color,
        width: _model!.strokeWidth(_weight),
      );
    } else {
      _draft = _build(start, pt);
    }
    _bump();
  }

  void _panEnd() {
    final d = _draft;
    _draft = null;
    _dragStart = null;
    if (d != null) {
      final tiny = switch (d) {
        ArrowMark() =>
          (d.to.x - d.from.x).abs() + (d.to.y - d.from.y).abs() < 2,
        RectMark() => (d.b.x - d.a.x).abs() + (d.b.y - d.a.y).abs() < 2,
        _ => false,
      };
      if (!tiny) setState(() => _model!.add(d));
    }
    _bump();
  }

  Future<void> _tapText(ImageViewport vp, Offset p) async {
    if (_tool != AnnotationTool.text || !vp.contains(p.dx, p.dy)) return;
    final at = vp.toImage(p.dx, p.dy);
    final text = await _askText();
    if (text == null || text.trim().isEmpty || !mounted) return;
    final m = _model!;
    setState(
      () => m.add(
        TextMark(
          at: at,
          text: text.trim(),
          fontSize: m.textSize(_weight),
          color: _color,
          width: m.strokeWidth(_weight),
        ),
      ),
    );
  }

  Future<String?> _askText() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          'Texto',
          style: AppFonts.inter(size: 16, weight: FontWeight.w600),
        ),
        content: TextField(
          key: const ValueKey('editor-text'),
          controller: c,
          autofocus: true,
          maxLength: 80,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.pop(ctx, v),
          style: AppFonts.inter(size: 15),
          decoration: AppTextField.decoration(hint: 'Etiqueta'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Añadir'),
          ),
        ],
      ),
    );
  }

  Future<void> _done() async {
    final img = _image;
    final m = _model;
    if (img == null || m == null || _saving) return;
    setState(() => _saving = true);
    try {
      final png = await renderAnnotatedPng(img, m.marks);
      if (mounted) Navigator.of(context).pop(EditorResult(png: png, model: m));
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        showToast(context, 'No se pudo generar la imagen');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final m = _model;
    return Scaffold(
      backgroundColor: AppColors.terminalBg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Cancelar',
                      style: AppFonts.inter(size: 14, color: AppColors.muted),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Text('Marcar imagen', style: AppText.routeTitle),
                    ),
                  ),
                  TextButton(
                    onPressed: img == null || _saving ? null : _done,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            'Listo',
                            style: AppFonts.inter(
                              size: 14,
                              weight: FontWeight.w600,
                              color: img == null
                                  ? AppColors.faint
                                  : AppColors.accent,
                            ),
                          ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Text(
                        'No se pudo abrir la imagen',
                        style: AppText.body.copyWith(color: AppColors.danger),
                      ),
                    )
                  : img == null || m == null
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, c) {
                        final vp = ImageViewport(
                          imageWidth: m.imageWidth,
                          imageHeight: m.imageHeight,
                          boxWidth: c.maxWidth,
                          boxHeight: c.maxHeight,
                        );
                        return GestureDetector(
                          key: const ValueKey('editor-canvas'),
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (d) => _panStart(vp, d.localPosition),
                          onPanUpdate: (d) => _panUpdate(vp, d.localPosition),
                          onPanEnd: (_) => _panEnd(),
                          onPanCancel: _panEnd,
                          onTapUp: (d) =>
                              unawaited(_tapText(vp, d.localPosition)),
                          child: CustomPaint(
                            size: Size(c.maxWidth, c.maxHeight),
                            painter: AnnotationPainter(
                              image: img,
                              marks: m.marks,
                              viewport: vp,
                              draft: () => _draft,
                              repaint: _repaint,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (m != null) _toolbar(m),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(AnnotationModel m) {
    Widget tool(AnnotationTool t, IconData icon, String label) => _ToolButton(
      icon: icon,
      label: label,
      selected: _tool == t,
      onTap: () => setState(() => _tool = t),
    );
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              tool(AnnotationTool.pen, Icons.edit, 'Lápiz'),
              tool(AnnotationTool.arrow, Icons.north_east, 'Flecha'),
              tool(AnnotationTool.rect, Icons.crop_square, 'Rectángulo'),
              tool(AnnotationTool.text, Icons.text_fields, 'Texto'),
              _ToolButton(
                icon: Icons.line_weight,
                label: _weight == StrokeWeight.thin
                    ? 'Trazo fino'
                    : 'Trazo grueso',
                selected: _weight == StrokeWeight.thick,
                onTap: () => setState(
                  () => _weight = _weight == StrokeWeight.thin
                      ? StrokeWeight.thick
                      : StrokeWeight.thin,
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final c in AnnotationColors.all)
                _ColorDot(
                  color: c,
                  selected: _color == c,
                  onTap: () => setState(() => _color = c),
                ),
              _ToolButton(
                icon: Icons.undo,
                label: 'Deshacer',
                onTap: m.canUndo ? () => setState(m.undo) : null,
              ),
              _ToolButton(
                icon: Icons.redo,
                label: 'Rehacer',
                onTap: m.canRedo ? () => setState(m.redo) : null,
              ),
              _ToolButton(
                icon: Icons.delete_outline,
                label: 'Borrar marcas',
                onTap: m.isEmpty ? null : () => setState(m.clear),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    selected: selected,
    label: label,
    excludeSemantics: true,
    child: Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? AppColors.accentBg : Colors.transparent,
          ),
          child: Icon(
            icon,
            size: 22,
            color: onTap == null
                ? AppColors.faint
                : (selected ? AppColors.accent : AppColors.secondary),
          ),
        ),
      ),
    ),
  );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final int color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    selected: selected,
    label: 'Color ${_colorName(color)}',
    excludeSemantics: true,
    child: InkResponse(
      onTap: onTap,
      radius: 22,
      child: SizedBox(
        width: 40,
        height: 44,
        child: Center(
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color(color),
              border: Border.all(
                color: selected ? AppColors.text : AppColors.border,
                width: selected ? 3 : 1,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

String _colorName(int c) => switch (c) {
  AnnotationColors.accent => 'azul',
  AnnotationColors.waiting => 'naranja',
  AnnotationColors.danger => 'rojo',
  AnnotationColors.white => 'blanco',
  AnnotationColors.green => 'verde',
  _ => '',
};
