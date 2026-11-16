import 'dart:convert';
import 'dart:typed_data';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/annotate/annotation_model.dart';
import 'package:agentd_app/src/ui/fakes/sample_data.dart';
import 'package:agentd_app/src/ui/screens/session_screen.dart';
import 'package:agentd_app/src/ui/widgets/attachments/attachment.dart';
import 'package:agentd_app/src/ui/widgets/attachments/attachment_source.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:agentd_app/src/ui/theme.dart';

import 'helpers.dart';

// 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _Source implements AttachmentSource {
  _Source(this.count);
  final int count;
  int galleryCalls = 0;
  int cameraCalls = 0;
  int? lastLimit;

  @override
  Future<List<PickedImage>> gallery({required int limit}) async {
    galleryCalls++;
    lastLimit = limit;
    return [for (var i = 0; i < count; i++) (bytes: _png, extension: 'png')];
  }

  @override
  Future<PickedImage?> camera() async {
    cameraCalls++;
    return (bytes: _png, extension: 'jpg');
  }
}

AgentSession _session() =>
    sampleSessions(DateTime.now()).firstWhere((s) => s.name == 'pando@agentd');

Future<Fakes> _pump(WidgetTester tester, _Source src) async {
  final f = Fakes();
  tester.view.physicalSize = const Size(390, 844) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...f.overrides,
        attachmentSourceProvider.overrideWithValue(src),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: SessionScreen(session: _session()),
      ),
    ),
  );
  await settle(tester);
  return f;
}

void main() {
  setUp(setUpUiTests);

  group('composePrompt', () {
    test('text then a blank line and one path per line', () {
      expect(
        composePrompt('  mira esto ', ['/a/1.png', '/a/2.png']),
        'mira esto\n\n/a/1.png\n/a/2.png',
      );
    });
    test('empty text is only the paths', () {
      expect(composePrompt('', ['/a/1.png']), '/a/1.png');
      expect(
        composePrompt('   ', ['/a/1.png', '/a/2.png']),
        '/a/1.png\n/a/2.png',
      );
    });
    test('no images is just the text', () {
      expect(composePrompt(' hola ', const []), 'hola');
    });
  });

  group('AttachmentsController', () {
    test('caps at $kMaxAttachments and reports how many fit', () {
      final c = AttachmentsController();
      final imgs = [
        for (var i = 0; i < 8; i++) (bytes: Uint8List(1), extension: 'png'),
      ];
      expect(c.addAll(imgs), kMaxAttachments);
      expect(c.remaining, 0);
      expect(c.addAll(imgs), 0);
    });

    test(
      'an edit replaces what is sent; no marks means the original again',
      () {
        final c = AttachmentsController()
          ..addAll([
            (bytes: Uint8List.fromList([1]), extension: 'jpg'),
          ]);
        final a = c.items.single;
        expect(a.sendExtension, 'jpg');
        expect(a.sendBytes, [1]);
        final m = AnnotationModel(imageWidth: 4, imageHeight: 4)
          ..add(const PenMark(points: [Pt(0, 0)], color: 1, width: 1));
        a.remotePath = '/old';
        c.setEdit(a.id, m, Uint8List.fromList([9]));
        expect((a.sendExtension, a.remotePath), ('png', null));
        expect(a.sendBytes, [9]);
        c.setEdit(
          a.id,
          AnnotationModel(imageWidth: 4, imageHeight: 4),
          Uint8List.fromList([9]),
        );
        expect((a.sendExtension, a.edited), ('jpg', false));
      },
    );
  });

  group('composer attachments', () {
    testWidgets('+ opens the sheet; gallery adds thumbnails; x removes one', (
      tester,
    ) async {
      final src = _Source(2);
      await _pump(tester, src);
      await tester.tap(find.bySemanticsLabel('Adjuntar imagen'));
      await settle(tester);
      expect(find.text('Galería'), findsOneWidget);
      expect(find.text('Cámara'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('attach-gallery')));
      await settle(tester);
      expect(src.galleryCalls, 1);
      expect(src.lastLimit, kMaxAttachments);
      expect(find.byKey(const ValueKey('attachment-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-2')), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Quitar imagen 1'));
      await settle(tester);
      expect(find.byKey(const ValueKey('attachment-1')), findsNothing);
      expect(find.byKey(const ValueKey('attachment-2')), findsOneWidget);
    });

    testWidgets('camera adds one image', (tester) async {
      final src = _Source(0);
      await _pump(tester, src);
      await tester.tap(find.bySemanticsLabel('Adjuntar imagen'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('attach-camera')));
      await settle(tester);
      expect(src.cameraCalls, 1);
      expect(find.byKey(const ValueKey('attachment-1')), findsOneWidget);
    });

    testWidgets(
      'sends with empty text: uploads, one prompt of paths, attachments cleared',
      (tester) async {
        final src = _Source(2);
        final f = await _pump(tester, src);
        await tester.tap(find.bySemanticsLabel('Adjuntar imagen'));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('attach-gallery')));
        await settle(tester);
        await tester.tap(find.bySemanticsLabel('Enviar'));
        await settle(tester);
        expect(f.sessions.uploads, hasLength(2));
        final prompt = f.sessions.calls.singleWhere(
          (c) => c.method == 'prompt',
        );
        expect(prompt.arg, f.sessions.uploads.keys.join('\n'));
        expect(find.byKey(const ValueKey('attachment-1')), findsNothing);
      },
    );

    testWidgets(
      'a failed upload keeps text and attachments and shows the reason',
      (tester) async {
        final src = _Source(1);
        final f = await _pump(tester, src);
        f.sessions.uploadError = StateError('sin espacio');
        await tester.tap(find.bySemanticsLabel('Adjuntar imagen'));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('attach-gallery')));
        await settle(tester);
        await tester.enterText(find.byKey(const ValueKey('composer')), 'mira');
        await tester.tap(find.bySemanticsLabel('Enviar'));
        await settle(tester);
        expect(
          find.textContaining('No se pudieron subir las imágenes: sin espacio'),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('attachment-1')), findsOneWidget);
        expect(f.sessions.calls.where((c) => c.method == 'prompt'), isEmpty);
        expect(find.text('mira'), findsOneWidget);
      },
    );
  });
}
