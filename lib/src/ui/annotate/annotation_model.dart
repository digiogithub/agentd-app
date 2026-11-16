// Pure-Dart model of an image markup: marks live in IMAGE space (pixels of
// the original image), so the export is at full resolution whatever the size
// of the editing canvas. No widgets in here.

import 'dart:math' as math;

enum AnnotationTool { pen, arrow, rect, text }

/// A point in image pixels.
class Pt {
  const Pt(this.x, this.y);
  final double x;
  final double y;

  @override
  bool operator ==(Object other) => other is Pt && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Pt($x, $y)';
}

/// Palette of the editor (ARGB): accent, waiting, danger, white, green.
abstract final class AnnotationColors {
  static const accent = 0xFF9DB4FF;
  static const waiting = 0xFFF0A04B;
  static const danger = 0xFFFF9B9B;
  static const white = 0xFFFFFFFF;
  static const green = 0xFF3FB950;
  static const all = [accent, waiting, danger, white, green];
}

/// Stroke weight preset; the real width scales with the image size.
enum StrokeWeight {
  thin(0.004),
  thick(0.009);

  const StrokeWeight(this.fraction);

  /// Fraction of the image's longest side.
  final double fraction;

  /// Width in image pixels for an image of [w] x [h].
  double widthFor(double w, double h) => math.max(2, math.max(w, h) * fraction);
}

/// Font size in image pixels for text labels.
double textSizeFor(double w, double h, StrokeWeight weight) => math.max(
  14,
  math.max(w, h) * (weight == StrokeWeight.thin ? 0.028 : 0.045),
);

/// One mark. Immutable: edits replace it.
sealed class Mark {
  const Mark({required this.color, required this.width});
  final int color; // ARGB
  final double width; // image pixels
}

class PenMark extends Mark {
  const PenMark({
    required this.points,
    required super.color,
    required super.width,
  });
  final List<Pt> points;
}

class ArrowMark extends Mark {
  const ArrowMark({
    required this.from,
    required this.to,
    required super.color,
    required super.width,
  });
  final Pt from;
  final Pt to;
}

class RectMark extends Mark {
  const RectMark({
    required this.a,
    required this.b,
    required super.color,
    required super.width,
  });
  final Pt a;
  final Pt b;
}

class TextMark extends Mark {
  const TextMark({
    required this.at,
    required this.text,
    required this.fontSize,
    required super.color,
    required super.width,
  });

  /// Top-left corner of the text.
  final Pt at;
  final String text;
  final double fontSize;
}

/// The marks of one image with undo / redo. Snapshots of an immutable list
/// are kept, so every operation (including [clear]) is undoable.
class AnnotationModel {
  AnnotationModel({required this.imageWidth, required this.imageHeight});

  final double imageWidth;
  final double imageHeight;

  List<Mark> _marks = const [];
  final List<List<Mark>> _past = [];
  final List<List<Mark>> _future = [];

  List<Mark> get marks => _marks;
  bool get isEmpty => _marks.isEmpty;
  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;

  void _commit(List<Mark> next) {
    _past.add(_marks);
    _future.clear();
    _marks = List.unmodifiable(next);
  }

  void add(Mark m) => _commit([..._marks, m]);

  /// No-op when there is nothing to clear (so it leaves no history entry).
  void clear() {
    if (_marks.isNotEmpty) _commit(const []);
  }

  void undo() {
    if (_past.isEmpty) return;
    _future.add(_marks);
    _marks = _past.removeLast();
  }

  void redo() {
    if (_future.isEmpty) return;
    _past.add(_marks);
    _marks = _future.removeLast();
  }

  /// Independent copy (the editor works on a copy so "Cancelar" leaves the
  /// attachment's model untouched). History is kept.
  AnnotationModel copy() {
    final c = AnnotationModel(imageWidth: imageWidth, imageHeight: imageHeight);
    c._marks = _marks;
    c._past.addAll(_past);
    c._future.addAll(_future);
    return c;
  }

  double strokeWidth(StrokeWeight w) => w.widthFor(imageWidth, imageHeight);
  double textSize(StrokeWeight w) => textSizeFor(imageWidth, imageHeight, w);
}

/// Maps between the editing canvas (screen) and image space for an image
/// shown with `BoxFit.contain` inside [box].
class ImageViewport {
  ImageViewport({
    required this.imageWidth,
    required this.imageHeight,
    required this.boxWidth,
    required this.boxHeight,
  }) : scale = math.min(boxWidth / imageWidth, boxHeight / imageHeight),
       dx =
           (boxWidth -
               imageWidth *
                   math.min(boxWidth / imageWidth, boxHeight / imageHeight)) /
           2,
       dy =
           (boxHeight -
               imageHeight *
                   math.min(boxWidth / imageWidth, boxHeight / imageHeight)) /
           2;

  final double imageWidth;
  final double imageHeight;
  final double boxWidth;
  final double boxHeight;

  /// Screen pixels per image pixel.
  final double scale;
  final double dx;
  final double dy;

  Pt toImage(double sx, double sy) => Pt((sx - dx) / scale, (sy - dy) / scale);
  Pt toScreen(Pt p) => Pt(p.x * scale + dx, p.y * scale + dy);

  /// Whether the screen point falls on the image.
  bool contains(double sx, double sy) =>
      sx >= dx &&
      sy >= dy &&
      sx <= dx + imageWidth * scale &&
      sy <= dy + imageHeight * scale;

  /// [toImage] clamped to the image bounds.
  Pt toImageClamped(double sx, double sy) {
    final p = toImage(sx, sy);
    return Pt(
      p.x.clamp(0, imageWidth).toDouble(),
      p.y.clamp(0, imageHeight).toDouble(),
    );
  }
}
