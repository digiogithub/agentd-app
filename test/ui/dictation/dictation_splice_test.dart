import 'package:agentd_app/src/ui/widgets/dictation/dictation_splice.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue v(String t, int a, [int? b]) => TextEditingValue(
  text: t,
  selection: TextSelection(baseOffset: a, extentOffset: b ?? a),
);

void main() {
  test('cursor at start', () {
    final r = DictationSplice.start(v('world', 0)).apply('hello');
    expect(r.text, 'hello world');
    expect(r.selection.baseOffset, 5);
  });

  test('cursor in the middle keeps both sides and adds spaces', () {
    final r = DictationSplice.start(v('ab cd', 2)).apply('xyz');
    expect(r.text, 'ab xyz cd');
    final r2 = DictationSplice.start(v('abcd', 2)).apply('xyz');
    expect(r2.text, 'ab xyz cd');
  });

  test('cursor at end', () {
    final r = DictationSplice.start(v('hola', 4)).apply('que tal');
    expect(r.text, 'hola que tal');
    expect(r.selection.baseOffset, r.text.length);
  });

  test('no extra space next to existing whitespace', () {
    expect(DictationSplice.start(v('hola ', 5)).apply('x').text, 'hola x');
    expect(DictationSplice.start(v('a\nb', 2)).apply('x').text, 'a\nx b');
  });

  test('selection is replaced', () {
    final r = DictationSplice.start(v('one two three', 4, 7)).apply('2');
    expect(r.text, 'one 2 three');
  });

  test('reversed selection works', () {
    expect(
      DictationSplice.start(v('one two three', 7, 4)).apply('2').text,
      'one 2 three',
    );
  });

  test('successive partials replace the previous one', () {
    final sp = DictationSplice.start(v('ab cd', 2));
    expect(sp.apply('hel').text, 'ab hel cd');
    expect(sp.apply('hello wor').text, 'ab hello wor cd');
    final fin = sp.apply('hello world');
    expect(fin.text, 'ab hello world cd');
    expect(fin.selection.baseOffset, 'ab hello world'.length);
  });

  test('empty heard text restores the original', () {
    final sp = DictationSplice.start(v('ab cd', 2));
    sp.apply('x');
    final r = sp.apply('  ');
    expect(r.text, 'ab cd');
    expect(r.selection.baseOffset, 2);
  });

  test('invalid selection appends', () {
    final r = DictationSplice.start(const TextEditingValue(text: 'abc'))
        .apply('d');
    expect(r.text, 'abc d');
  });
}
