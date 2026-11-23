// Chat text can be selected and copied, code blocks have a copy button and
// the composer takes a paste.

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/ui/chat/table_parser.dart';
import 'package:agentd_app/src/ui/fakes/sample_data.dart';
import 'package:agentd_app/src/ui/screens/chat_tab.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers.dart';

AgentSession _session() => sampleSessions(DateTime.now()).firstWhere((s) => s.name == 'pando@agentd');

Future<void> _pumpChat(WidgetTester tester, List<ChatItem> items) {
  final s = _session();
  return pumpUi(
    tester,
    Scaffold(
      body: ChatTab(session: s, view: SessionView(session: s, items: items), composerFocus: FocusNode(), onOpenMailbox: () {}),
    ),
  );
}

/// A fake system clipboard; returns what was last copied.
String? Function() _mockClipboard(WidgetTester tester, {String? initial}) {
  String? data = initial;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        data = (call.arguments as Map)['text'] as String?;
        return null;
      case 'Clipboard.getData':
        return data == null ? null : {'text': data};
      case 'Clipboard.hasStrings':
        return {'value': data != null && data!.isNotEmpty};
    }
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return () => data;
}

Future<void> _longPress(WidgetTester tester, Finder f) async {
  await tester.longPress(f);
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

void main() {
  setUp(setUpUiTests);

  test('code fences split agent text into code segments', () {
    final segs = parseChatSegments('Así:\n\n````\nfunc main() {\n\n    run()\n}\n````\n\nY **listo**.');
    expect(segs.map((s) => s.runtimeType), [TextSegment, CodeSegment, TextSegment]);
    expect((segs[0] as TextSegment).text, 'Así:');
    expect((segs[1] as CodeSegment).code, 'func main() {\n\n    run()\n}');
    expect((segs[2] as TextSegment).text, 'Y **listo**.');
    // Code only, and a block still being written.
    expect((parseChatSegments('````\nls -la\n````').single as CodeSegment).code, 'ls -la');
    expect((parseChatSegments('Mira:\n\n````\nx := 1').last as CodeSegment).code, 'x := 1');
    // Table drawing inside code is not a table.
    expect(parseChatSegments('````\n| a | b |\n|---|---|\n| 1 | 2 |\n````').single, isA<CodeSegment>());
  });

  testWidgets('long-press selects agent text and Copy copies it', (tester) async {
    final copied = _mockClipboard(tester);
    await _pumpChat(tester, const [
      ChatItem(role: ChatRole.user, text: 'Revisa el servidor'),
      ChatItem(role: ChatRole.agent, text: 'Reinicia el **daemon** ahora'),
    ]);
    expect(find.byType(SelectionArea), findsOneWidget);
    await _longPress(tester, find.textContaining('Reinicia', findRichText: true));
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // The selection spans the entries of the chat.
    expect(copied(), contains('Revisa el servidor'));
    expect(copied(), contains('Reinicia el daemon ahora'));
  });

  testWidgets('user messages and tool output are selectable; the card still expands', (tester) async {
    _mockClipboard(tester);
    await _pumpChat(tester, const [
      ChatItem(role: ChatRole.user, text: 'Lanza los tests'),
      ChatItem(role: ChatRole.tool, title: 'Bash', text: 'go test ./...\nok  example/pkg', meta: 'ok'),
    ]);
    await _longPress(tester, find.textContaining('Lanza', findRichText: true));
    expect(find.text('Copy'), findsOneWidget);
    // With a selection up, the first tap only dismisses it; the next one
    // opens the tool card as usual.
    await tester.tap(find.text('Bash'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Copy'), findsNothing);
    await tester.tap(find.text('Bash'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.textContaining('example/pkg'), findsOneWidget);
    await _longPress(tester, find.textContaining('example/pkg'));
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('a code block is monospace text with a copy button', (tester) async {
    final copied = _mockClipboard(tester);
    await _pumpChat(tester, const [ChatItem(role: ChatRole.agent, text: 'Instálalo así:\n\n````\nsudo dpkg -i **a**.deb\n  second_line\n````\n\nY reinicia.')]);
    expect(find.byKey(const ValueKey('code-block')), findsOneWidget);
    // No markup parsing inside the block.
    expect(find.text('sudo dpkg -i **a**.deb\n  second_line'), findsOneWidget);
    expect(find.textContaining('Y reinicia', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('copy-code')));
    await tester.pump();
    expect(copied(), 'sudo dpkg -i **a**.deb\n  second_line');
    expect(find.text('Código copiado'), findsOneWidget);
  });

  testWidgets('the composer takes a paste', (tester) async {
    _mockClipboard(tester, initial: 'texto pegado');
    await _pumpChat(tester, const [ChatItem(role: ChatRole.agent, text: 'Hola')]);
    final composer = find.byKey(const ValueKey('composer'));
    await tester.tap(composer);
    await tester.pump();
    await _longPress(tester, composer);
    expect(find.text('Paste'), findsOneWidget);
    await tester.tap(find.text('Paste'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(tester.widget<TextField>(composer).controller!.text, 'texto pegado');
  });
}
