import 'dart:convert';
import 'dart:typed_data';

import 'package:agentd_app/src/agentd/errors.dart';
import 'package:agentd_app/src/agentd/frames.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('frame header is type + big-endian uint32 length', () {
    expect(encodeFrame(FrameType.data, utf8.encode('hi')), [0x44, 0, 0, 0, 2, 0x68, 0x69]);
    expect(encodeFrame(FrameType.detach), [0x58, 0, 0, 0, 0]);
  });

  test('resize payload is cols then rows, uint16 big-endian', () {
    expect(encodeFrame(FrameType.resize, resizePayload(300, 50)), [0x52, 0, 0, 0, 4, 0x01, 0x2c, 0x00, 0x32]);
    expect(parseResize([0x01, 0x2c, 0x00, 0x32]), (300, 50));
    expect(() => parseResize([0, 0, 0, 1]), throwsA(isA<AgentdTransportError>()));
  });

  test('exit payload is decimal text', () {
    expect(parseExit(ascii.encode('0')), 0);
    expect(parseExit(ascii.encode('-1')), -1);
    expect(parseExit(ascii.encode(' 137 ')), 137);
    expect(() => parseExit([]), throwsA(isA<AgentdTransportError>()));
    expect(() => parseExit(ascii.encode('x')), throwsA(isA<AgentdTransportError>()));
  });

  test('decoder handles byte-at-a-time input and several frames per chunk', () {
    final bytes = [
      ...encodeFrame(FrameType.data, utf8.encode('hello')),
      ...encodeFrame(FrameType.data, const []),
      ...encodeFrame(FrameType.exit, ascii.encode('3')),
    ];
    final d = FrameDecoder();
    final frames = <Frame>[];
    for (final b in bytes) {
      frames.addAll(d.add([b]));
    }
    expect(frames.map((f) => f.type), [FrameType.data, FrameType.data, FrameType.exit]);
    expect(utf8.decode(frames[0].payload), 'hello');
    expect(frames[1].payload, isEmpty);
    expect(d.pendingLength, 0);

    final all = FrameDecoder().add(Uint8List.fromList(bytes));
    expect(all.length, 3);
  });

  test('decoder rejects unknown types and oversize payloads', () {
    expect(() => FrameDecoder().add([0x5a, 0, 0, 0, 0]), throwsA(isA<AgentdTransportError>()));
    expect(() => FrameDecoder().add([0x44, 0, 0x20, 0, 0]), throwsA(isA<AgentdTransportError>()));
    expect(() => FrameDecoder().add([0x45, 0, 0, 0, 1, 0x78]), throwsA(isA<AgentdTransportError>()));
  });

  test('encodeData splits at 1 MiB', () {
    final frames = encodeData(Uint8List(maxFrameSize + 10));
    expect(frames.length, 2);
    expect(frames[0].length, frameHeaderSize + maxFrameSize);
    expect(frames[1].length, frameHeaderSize + 10);
    expect(() => encodeFrame(FrameType.data, Uint8List(maxFrameSize + 1)), throwsA(isA<AgentdTransportError>()));
  });
}
