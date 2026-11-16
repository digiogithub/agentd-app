import 'dart:ui' as ui;

import 'package:agentd_app/src/ui/annotate/annotation_model.dart';
import 'package:agentd_app/src/ui/annotate/annotation_painter.dart';
import 'package:flutter_test/flutter_test.dart';

Mark _pen(double x) => PenMark(
  points: [Pt(x, 0), Pt(x + 1, 1)],
  color: AnnotationColors.danger,
  width: 4,
);

void main() {
  group('AnnotationModel', () {
    test('add, undo, redo', () {
      final m = AnnotationModel(imageWidth: 1000, imageHeight: 500);
      expect(m.isEmpty, isTrue);
      expect(m.canUndo, isFalse);
      m.add(_pen(1));
      m.add(_pen(2));
      expect(m.marks, hasLength(2));
      m.undo();
      expect(m.marks, hasLength(1));
      expect(m.canRedo, isTrue);
      m.redo();
      expect(m.marks, hasLength(2));
      m.undo();
      m.add(_pen(3)); // a new mark drops the redo stack
      expect(m.canRedo, isFalse);
      expect((m.marks.last as PenMark).points.first.x, 3);
    });

    test('clear is undoable and a no-op when empty', () {
      final m = AnnotationModel(imageWidth: 10, imageHeight: 10);
      m.clear();
      expect(m.canUndo, isFalse);
      m.add(_pen(1));
      m.clear();
      expect(m.isEmpty, isTrue);
      m.undo();
      expect(m.marks, hasLength(1));
    });

    test('copy is independent', () {
      final m = AnnotationModel(imageWidth: 10, imageHeight: 10)..add(_pen(1));
      final c = m.copy()..add(_pen(2));
      expect(m.marks, hasLength(1));
      expect(c.marks, hasLength(2));
      c.undo();
      c.undo();
      expect(c.isEmpty, isTrue);
      expect(m.marks, hasLength(1));
    });

    test('marks list cannot be mutated from outside', () {
      final m = AnnotationModel(imageWidth: 10, imageHeight: 10)..add(_pen(1));
      expect(() => m.marks.add(_pen(2)), throwsUnsupportedError);
    });

    test('stroke width scales with the image, not the canvas', () {
      final small = AnnotationModel(imageWidth: 500, imageHeight: 400);
      final big = AnnotationModel(imageWidth: 4000, imageHeight: 3000);
      expect(
        big.strokeWidth(StrokeWeight.thin),
        greaterThan(small.strokeWidth(StrokeWeight.thin)),
      );
      expect(
        small.strokeWidth(StrokeWeight.thick),
        greaterThan(small.strokeWidth(StrokeWeight.thin)),
      );
      expect(big.strokeWidth(StrokeWeight.thin), closeTo(16, 1e-9));
    });
  });

  group('ImageViewport', () {
    test('maps screen to image space with contain fit and back', () {
      // 2000x1000 image in a 400x400 box: scale 0.2, letterboxed vertically.
      final vp = ImageViewport(
        imageWidth: 2000,
        imageHeight: 1000,
        boxWidth: 400,
        boxHeight: 400,
      );
      expect(vp.scale, closeTo(0.2, 1e-9));
      expect(vp.dx, 0);
      expect(vp.dy, closeTo(100, 1e-9));
      expect(vp.toImage(0, 100), const Pt(0, 0));
      final p = vp.toImage(200, 200);
      expect(p.x, closeTo(1000, 1e-9));
      expect(p.y, closeTo(500, 1e-9));
      final back = vp.toScreen(p);
      expect(back.x, closeTo(200, 1e-9));
      expect(back.y, closeTo(200, 1e-9));
      expect(vp.contains(200, 50), isFalse);
      expect(vp.contains(200, 200), isTrue);
    });

    test('toImageClamped stays on the image', () {
      final vp = ImageViewport(
        imageWidth: 100,
        imageHeight: 100,
        boxWidth: 100,
        boxHeight: 100,
      );
      expect(vp.toImageClamped(-50, 500), const Pt(0, 100));
    });
  });

  testWidgets('renderAnnotatedPng keeps the image resolution', (tester) async {
    await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 64, 32),
        ui.Paint()..color = const ui.Color(0xFF112233),
      );
      final img = await rec.endRecording().toImage(64, 32);
      final png = await renderAnnotatedPng(img, [
        _pen(5),
        const RectMark(
          a: Pt(1, 1),
          b: Pt(30, 20),
          color: AnnotationColors.accent,
          width: 2,
        ),
      ]);
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      final codec = await ui.instantiateImageCodec(png);
      final out = (await codec.getNextFrame()).image;
      expect((out.width, out.height), (64, 32));
    });
  });
}
