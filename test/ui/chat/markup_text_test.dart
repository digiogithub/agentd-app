import 'package:agentd_app/src/ui/chat/markup_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers.dart';

void main() {
  test('blocks: heading, paragraph, list items with depth', () {
    final b = parseMarkupBlocks('**Hola** mundo\nsigue\n\n### Antes de RAG\n- uno\n  - dos\n1. tres');
    expect(b.map((x) => x.runtimeType.toString()), ['ParagraphBlock', 'HeadingBlock', 'ListItemBlock', 'ListItemBlock', 'ListItemBlock']);
    expect((b[0] as ParagraphBlock).text, '**Hola** mundo\nsigue');
    expect((b[1] as HeadingBlock).text, 'Antes de RAG');
    expect(((b[3] as ListItemBlock).text, (b[3] as ListItemBlock).depth), ('dos', 1));
    expect((b[4] as ListItemBlock).marker, '1.');
  });

  test('inline: bold, code, escapes', () {
    final r = parseMarkupInline(r'**No** usa `a_b` y 2\*3 \[x\]');
    expect(r.map((x) => (x.text, x.bold, x.code)), [
      ('No', true, false),
      (' usa ', false, false),
      ('a_b', false, true),
      (' y 2*3 [x]', false, false),
    ]);
    expect(unmarkup(r'### **Total** `x` 2\*3'), 'Total x 2*3');
  });

  testWidgets('MarkupText draws the heading and the item text', (tester) async {
    setUpUiTests();
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: MarkupText('### Si llega el momento\n- usa `grant_call_id`', style: TextStyle(fontSize: 14))),
        ),
      ),
    );
    expect(find.text('Si llega el momento'), findsOneWidget);
    expect(find.textContaining('grant_call_id', findRichText: true), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
  });
}
