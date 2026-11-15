import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agentd_app/src/agentd/client.dart';
import 'package:agentd_app/src/agentd/errors.dart';
import 'package:agentd_app/src/agentd/frames.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_daemon.dart';

void main() {
  late FakeDaemon d;
  late AgentdClient c;

  setUp(() {
    d = FakeDaemon(serverChunk: 4);
    c = AgentdClient(d.dial, timeout: const Duration(seconds: 2));
  });

  test('handshake, output, input, resize, focus, exit', () async {
    final received = <Frame>[];
    final gotDetachOrInput = Completer<void>();
    late FakeConn server;
    d.on('attach', (k) {
      server = k;
      // OK line and the redraw frame in the same write: the redraw must not
      // be lost in the line decoder.
      k.bytes([...utf8.encode('{"ok":true}\n'), ...encodeFrame(FrameType.data, utf8.encode('\x1b[2J❯ '))]);
      final dec = FrameDecoder();
      k.after.stream.listen((b) {
        received.addAll(dec.add(b));
        if (received.length >= 4 && !gotDetachOrInput.isCompleted) gotDetachOrInput.complete();
      });
    });

    final pty = await c.attach('claude@webapp', cols: 100, rows: 30, passive: true, history: 200);
    expect(d.lastArgs('attach'), {'name': 'claude@webapp', 'cols': 100, 'rows': 30, 'passive': true, 'history': 200});

    final out = <int>[];
    final outSub = pty.stream.listen(out.addAll);

    pty.add(utf8.encode('ls\r'));
    pty.resize(120, 40);
    pty.focus(true);
    pty.addAutomatic(utf8.encode('\x1b[1;1R'));
    await gotDetachOrInput.future.timeout(const Duration(seconds: 2));
    expect(received[0].type, FrameType.data);
    expect(utf8.decode(received[0].payload), 'ls\r');
    expect(received[1].type, FrameType.resize);
    expect(parseResize(received[1].payload), (120, 40));
    expect(received[2].type, FrameType.focus);
    expect(received[2].payload, [1]);
    expect(received[3].type, FrameType.auto);

    server.bytes(encodeFrame(FrameType.data, utf8.encode('output')));
    server.bytes(encodeFrame(FrameType.exit, ascii.encode('7')));
    expect(await pty.exitCode.timeout(const Duration(seconds: 2)), 7);
    await pty.done;
    expect(utf8.decode(out), '\x1b[2J❯ output');
    expect(pty.isClosed, isTrue);
    await outSub.cancel();
  });

  test('close sends X and leaves exitCode null', () async {
    final frames = <Frame>[];
    final gotX = Completer<void>();
    d.on('attach', (k) {
      k.ok();
      final dec = FrameDecoder();
      k.after.stream.listen((b) {
        for (final f in dec.add(b)) {
          frames.add(f);
          if (f.type == FrameType.detach && !gotX.isCompleted) gotX.complete();
        }
      });
    });
    final pty = await c.attach('s', observe: true);
    expect(d.lastArgs('attach'), {'name': 's', 'cols': 80, 'rows': 24, 'observe': true});
    await pty.close();
    await gotX.future.timeout(const Duration(seconds: 2));
    expect(frames.single.payload, isEmpty);
    expect(await pty.exitCode, isNull);
    expect(d.clientEnds.last.isClosed, isTrue);
  });

  test('daemon closing the channel ends the session without exit code', () async {
    d.on('attach', (k) async {
      k.ok();
      await k.close();
    });
    final pty = await c.attach('s');
    final sub = pty.stream.listen((_) {});
    expect(await pty.exitCode.timeout(const Duration(seconds: 2)), isNull);
    await pty.done;
    await sub.cancel();
  });

  test('attach refused: AgentdError and channel closed', () async {
    d.on('attach', (k) => k.fail('no session "x"', code: 'not_found'));
    await expectLater(c.attach('x'), throwsA(isA<AgentdError>().having((e) => e.code, 'code', 'not_found')));
    expect(d.clientEnds.last.isClosed, isTrue);
  });

  test('garbage frame is a stream error', () async {
    d.on('attach', (k) => k.bytes([...utf8.encode('{"ok":true}\n'), 0x5a, 0, 0, 0, 0]));
    final pty = await c.attach('s');
    final errors = <Object>[];
    final done = Completer<void>();
    pty.stream.listen((_) {}, onError: errors.add, onDone: done.complete);
    await done.future.timeout(const Duration(seconds: 2));
    expect(errors.single, isA<AgentdTransportError>());
    expect(await pty.exitCode, isNull);
  });

  test('large input is split into 1 MiB D frames', () async {
    final sizes = <int>[];
    final all = Completer<void>();
    d.on('attach', (k) {
      k.ok();
      final dec = FrameDecoder();
      k.after.stream.listen((b) {
        sizes.addAll(dec.add(b).map((f) => f.payload.length));
        if (sizes.length == 2 && !all.isCompleted) all.complete();
      });
    });
    final pty = await c.attach('s');
    pty.add(Uint8List(maxFrameSize + 1));
    await all.future.timeout(const Duration(seconds: 5));
    expect(sizes, [maxFrameSize, 1]);
    await pty.close();
  });
}
