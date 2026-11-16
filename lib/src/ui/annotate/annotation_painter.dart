// Painting of an [AnnotationModel]: on screen (CustomPainter) and into a PNG.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'annotation_model.dart';

/// Draws [marks] on [canvas], whose units are image pixels.
void paintMarks(Canvas canvas, Iterable<Mark> marks) {
  for (final m in marks) {
    switch (m) {
      case PenMark():
        _pen(canvas, m);
      case ArrowMark():
        _arrow(canvas, m);
      case RectMark():
        canvas.drawRect(
          Rect.fromPoints(Offset(m.a.x, m.a.y), Offset(m.b.x, m.b.y)),
          _stroke(m),
        );
      case TextMark():
        _text(canvas, m);
    }
  }
}

Paint _stroke(Mark m) => Paint()
  ..color = Color(m.color)
  ..style = PaintingStyle.stroke
  ..strokeWidth = m.width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

void _pen(Canvas canvas, PenMark m) {
  if (m.points.isEmpty) return;
  if (m.points.length == 1) {
    final p = m.points.first;
    canvas.drawCircle(
      Offset(p.x, p.y),
      m.width / 2,
      Paint()..color = Color(m.color),
    );
    return;
  }
  final path = Path()..moveTo(m.points.first.x, m.points.first.y);
  for (final p in m.points.skip(1)) {
    path.lineTo(p.x, p.y);
  }
  canvas.drawPath(path, _stroke(m));
}

void _arrow(Canvas canvas, ArrowMark m) {
  final a = Offset(m.from.x, m.from.y);
  final b = Offset(m.to.x, m.to.y);
  final len = (b - a).distance;
  if (len < 1) return;
  final paint = _stroke(m);
  canvas.drawLine(a, b, paint);
  final head = math.min(len * 0.5, m.width * 4 + 8);
  final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
  for (final s in const [-1, 1]) {
    final t = angle + math.pi + s * math.pi / 6;
    canvas.drawLine(b, b + Offset(math.cos(t), math.sin(t)) * head, paint);
  }
}

void _text(Canvas canvas, TextMark m) {
  final tp = TextPainter(
    text: TextSpan(
      text: m.text,
      style: TextStyle(
        color: Color(m.color),
        fontSize: m.fontSize,
        fontWeight: FontWeight.w700,
        shadows: [
          Shadow(
            color: const Color(0xCC000000),
            blurRadius: m.fontSize * 0.12,
            offset: Offset(0, m.fontSize * 0.04),
          ),
        ],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: math.max(m.fontSize, 1e6));
  tp.paint(canvas, Offset(m.at.x, m.at.y));
}

/// Paints the image fitted into the canvas and the marks on top (editor).
class AnnotationPainter extends CustomPainter {
  AnnotationPainter({
    required this.image,
    required this.marks,
    required this.viewport,
    this.draft,
    super.repaint,
  });

  final ui.Image? image;
  final List<Mark> marks;
  final ImageViewport viewport;

  /// Mark being drawn (not yet committed).
  final Mark? Function()? draft;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(viewport.dx, viewport.dy);
    canvas.scale(viewport.scale);
    final img = image;
    if (img != null) {
      canvas.drawImage(
        img,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    canvas.clipRect(
      Rect.fromLTWH(0, 0, viewport.imageWidth, viewport.imageHeight),
    );
    paintMarks(canvas, marks);
    final d = draft?.call();
    if (d != null) paintMarks(canvas, [d]);
    canvas.restore();
  }

  @override
  bool shouldRepaint(AnnotationPainter old) => true;
}

/// Renders [image] with [marks] at the image's own resolution as PNG bytes.
Future<Uint8List> renderAnnotatedPng(ui.Image image, List<Mark> marks) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawImage(image, Offset.zero, Paint());
  paintMarks(canvas, marks);
  final picture = recorder.endRecording();
  final out = await picture.toImage(image.width, image.height);
  try {
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('no se pudo codificar la imagen');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    out.dispose();
    picture.dispose();
  }
}
