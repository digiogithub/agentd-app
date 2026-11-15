import 'dart:convert';

import 'package:agentd_app/src/agentd/codec.dart';
import 'package:agentd_app/src/agentd/errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LineDecoder', () {
    test('joins partial chunks and splits several lines per chunk', () {
      final d = LineDecoder();
      expect(d.add(utf8.encode('{"a":')), isEmpty);
      expect(d.add(utf8.encode('1}\n{"b":2}\n{"c"')), ['{"a":1}', '{"b":2}']);
      expect(d.add(utf8.encode(':3}\r\n')), ['{"c":3}']);
      expect(d.pendingLength, 0);
    });

    test('decodes a UTF-8 rune split across chunks', () {
      final bytes = utf8.encode('{"t":"❯ ñ"}\n');
      final d = LineDecoder();
      final out = <String>[];
      for (final b in bytes) {
        out.addAll(d.add([b]));
      }
      expect(out, ['{"t":"❯ ñ"}']);
    });

    test('rejects a line over the limit, with or without newline', () {
      expect(() => LineDecoder(lineLimit: 8).add(utf8.encode('0123456789\n')), throwsA(isA<AgentdTransportError>()));
      final d = LineDecoder(lineLimit: 8);
      d.add(utf8.encode('01234'));
      expect(() => d.add(utf8.encode('56789')), throwsA(isA<AgentdTransportError>()));
      expect(LineDecoder(lineLimit: 8).add(utf8.encode('01234567\n')), ['01234567']);
    });

    test('limit leaves the rest raw for an upgrade', () {
      final d = LineDecoder(lineLimit: 16);
      final lines = d.add([...utf8.encode('{"ok":true}\n'), 0x44, 0, 0, 0, 0x0a, ...List.filled(40, 0x0a)], limit: 1);
      expect(lines, ['{"ok":true}']);
      final rest = d.takeRemainder();
      expect(rest.length, 45);
      expect(rest.first, 0x44);
    });
  });

  group('responses', () {
    test('ok with and without data', () {
      expect(decodeResponse('{"ok":true,"data":{"version":"1"}}'), {'version': '1'});
      expect(decodeResponse('{"ok":true}'), isNull);
    });

    test('error carries message, code and data', () {
      try {
        decodeResponse('{"ok":false,"error":"stale revision","code":"conflict","data":{"revision":4}}', op: 'act');
        fail('no error');
      } on AgentdError catch (e) {
        expect(e.message, 'stale revision');
        expect(e.code, AgentdErrorCode.conflict);
        expect(e.isConflict, isTrue);
        expect(e.op, 'act');
        expect(e.data, {'revision': 4});
      }
    });

    test('error without code is unclassified', () {
      expect(
        () => decodeResponse('{"ok":false,"error":"boom"}'),
        throwsA(isA<AgentdError>().having((e) => e.code, 'code', '').having((e) => e.message, 'msg', 'boom')),
      );
    });

    test('garbage is a transport error', () {
      expect(() => decodeResponse('not json'), throwsA(isA<AgentdTransportError>()));
      expect(() => decodeResponse('[1,2]'), throwsA(isA<AgentdTransportError>()));
      expect(() => decodeResponse('{"data":1}'), throwsA(isA<AgentdTransportError>()));
    });
  });

  test('encodeRequest writes one line, args omitted when null', () {
    expect(utf8.decode(encodeRequest('ping')), '{"op":"ping"}\n');
    expect(utf8.decode(encodeRequest('rm', {'name': 'x'})), '{"op":"rm","args":{"name":"x"}}\n');
  });

  test('compactArgs mirrors omitempty', () {
    expect(
      compactArgs({'a': null, 'b': false, 'c': '', 'd': 0, 'e': <String>[], 'f': <String, String>{}, 'g': 'x', 'id': 0}, keep: {'id'}),
      {'g': 'x', 'id': 0},
    );
  });
}
