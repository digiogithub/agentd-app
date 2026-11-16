import 'package:agentd_app/src/ui/chat/links.dart';
import 'package:agentd_app/src/ui/chat/table_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ChatTable _only(String t) {
  final s = parseChatSegments(t);
  expect(s, hasLength(1), reason: '$s');
  return (s.single as TableSegment).table;
}

void main() {
  group('box tables', () {
    test('basic with wrapped cell and indentation, joined with a space', () {
      final t = _only('''
  ┌──────────┬───────────┐
  │ Columna  │ Valor     │
  ├──────────┼───────────┤
  │ uno      │ texto que │
  │          │ sigue     │
  ├──────────┼───────────┤
  │ dos      │ 2         │
  └──────────┴───────────┘''');
      expect(t.header, ['Columna', 'Valor']);
      expect(t.rows, [
        ['uno', 'texto que sigue'],
        ['dos', '2'],
      ]);
    });

    test('no separators between body rows: continuation lines join', () {
      final t = _only('''
┌───────┬──────────┐
│ A     │ B        │
├───────┼──────────┤
│ uno   │ largo    │
│       │ texto    │
│ dos   │ x        │
└───────┴──────────┘''');
      expect(t.header, ['A', 'B']);
      expect(t.rows, [
        ['uno', 'largo texto'],
        ['dos', 'x'],
      ]);
    });

    test('heavy and double variants, with a ⏺ prefix', () {
      final t = _only('''
⏺ ╔════╦════╗
  ║ a  ║ b  ║
  ╠════╬════╣
  ║ 1  ║ 2  ║
  ╚════╩════╝''');
      expect(t.header, ['a', 'b']);
      expect(t.rows, [
        ['1', '2'],
      ]);
      final h = _only('┏━━┳━━┓\n┃a ┃b ┃\n┣━━╋━━┫\n┃1 ┃2 ┃\n┗━━┻━━┛');
      expect(h.rows.single, ['1', '2']);
    });

    test('cell containing a pipe-like char is sliced by border positions', () {
      final t = _only(
        '┌────┬────┐\n│ a  │ b  │\n├────┼────┤\n│ x| │ y  │\n└────┴────┘',
      );
      expect(t.rows.single, ['x|', 'y']);
    });

    test('ragged rows are not a table', () {
      const src = '┌──┬──┐\n│ a │ b │\n├──┼──┤\n│ 1 │\n└──┴──┘';
      final s = parseChatSegments(src);
      expect(s.single, isA<TextSegment>());
      expect((s.single as TextSegment).text, src);
    });
  });

  group('pipe tables', () {
    test('header, alignment row and body', () {
      final t = _only('| a | b |\n|---|:--:|\n| 1 | 2 |\n| 3 | 4 |');
      expect(t.header, ['a', 'b']);
      expect(t.rows, [
        ['1', '2'],
        ['3', '4'],
      ]);
      expect(t.toText(), 'a\tb\n1\t2\n3\t4');
    });
    test('without separator row it stays text', () {
      expect(
        parseChatSegments('| a | b |\n| 1 | 2 |').single,
        isA<TextSegment>(),
      );
    });
  });

  group('segments', () {
    test('text before and after a table', () {
      final s = parseChatSegments(
        'Resultado:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nFin.',
      );
      expect(s.map((e) => e.runtimeType), [
        TextSegment,
        TableSegment,
        TextSegment,
      ]);
      expect((s.first as TextSegment).text, 'Resultado:');
      expect((s.last as TextSegment).text, 'Fin.');
    });
    test('plain text is returned untouched', () {
      final s = parseChatSegments('hola\nmundo');
      expect((s.single as TextSegment).text, 'hola\nmundo');
    });
    test('two tables in a row of text', () {
      final s = parseChatSegments(
        '| a | b |\n|---|---|\n| 1 | 2 |\ntexto\n| c | d |\n|---|---|\n| 3 | 4 |',
      );
      expect(s.whereType<TableSegment>(), hasLength(2));
    });
  });

  group('findUrls', () {
    List<String> u(String t) => findUrls(t).map((m) => m.url).toList();
    test('trims trailing punctuation', () {
      expect(u('mira https://a.com/x, y https://b.org.'), [
        'https://a.com/x',
        'https://b.org',
      ]);
      expect(u('¿es https://a.com/?q=1?'), ['https://a.com/?q=1']);
      expect(u('(ver https://a.com/x)'), ['https://a.com/x']);
    });
    test('keeps balanced parens', () {
      expect(u('https://en.wikipedia.org/wiki/Dart_(language)'), [
        'https://en.wikipedia.org/wiki/Dart_(language)',
      ]);
      expect(u('(https://en.wikipedia.org/wiki/Dart_(language))'), [
        'https://en.wikipedia.org/wiki/Dart_(language)',
      ]);
    });
    test('ranges and scheme-only rejected', () {
      final m = findUrls('a http://x.io/p b').single;
      expect('a http://x.io/p b'.substring(m.start, m.end), 'http://x.io/p');
      expect(findUrls('https://'), isEmpty);
    });
  });
}
