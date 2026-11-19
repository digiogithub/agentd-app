import 'dart:async';
import 'dart:typed_data';

import 'package:agentd_app/src/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plaintext transport over an in-memory message pipe (no Noise), counting
/// frames by type.
class PlainTransport implements MuxTransport {
  PlainTransport(this.c);
  final MemoryMsgConn c;
  final Map<int, int> sent = {};
  final List<int> credits = [];

  @override
  void send(Uint8List plain) {
    sent[plain[0]] = (sent[plain[0]] ?? 0) + 1;
    if (plain[0] == muxCredit) credits.add(ByteData.sublistView(plain, 5).getUint32(0));
    c.write(plain);
  }

  @override
  Future<Uint8List?> recv() => c.read();

  @override
  Future<void> close() => c.close();
}

(RelayMux, RelayMux, PlainTransport, PlainTransport) muxPair() {
  final (a, b) = MemoryMsgConn.pair();
  final ta = PlainTransport(a);
  final tb = PlainTransport(b);
  return (RelayMux.client(ta), RelayMux.server(tb), ta, tb);
}

Future<Uint8List> readAll(Stream<Uint8List> s) async {
  final b = BytesBuilder(copy: false);
  await for (final c in s) {
    b.add(c);
  }
  return b.takeBytes();
}

Uint8List pattern(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xff));

void main() {
  test('echo on several streams with odd ids', () async {
    final (client, server, _, _) = muxPair();
    server.incoming.listen((s) async {
      await for (final b in s.stream) {
        s.add(b);
      }
      await s.close();
    });
    final s1 = client.open();
    final s2 = client.open();
    expect([s1.id, s2.id], [1, 3]);
    final got1 = s1.stream.first;
    final got2 = s2.stream.first;
    s1.add([1, 2, 3]);
    s2.add([4]);
    expect(await got1, [1, 2, 3]);
    expect(await got2, [4]);
  });

  test('transfers larger than the window in both directions', () async {
    final (client, server, tc, ts) = muxPair();
    final big = pattern(1 << 20); // 4x the window
    server.incoming.listen((s) async {
      // Read exactly the request, echo it, close.
      final got = BytesBuilder(copy: false);
      final sub = s.stream.listen(null);
      final all = Completer<void>();
      sub.onData((b) {
        got.add(b);
        if (got.length >= big.length) all.complete();
      });
      await all.future;
      await sub.cancel();
      s.add(got.takeBytes());
      await s.close();
    });
    final s = client.open();
    final echoed = readAll(s.stream);
    s.add(big);
    // No more than the window leaves before credit comes back.
    expect(s.pendingOut, big.length - muxInitialWindow);
    expect(await echoed.timeout(const Duration(seconds: 10)), big);
    expect(ts.credits, isNotEmpty);
    expect(tc.credits, isNotEmpty);
    expect([...ts.credits, ...tc.credits].every((c) => c >= muxGrantAfter), isTrue);
    expect(tc.sent[muxData], greaterThanOrEqualTo(big.length ~/ muxMaxData));
  });

  test('a paused reader holds back credit; resuming lets the sender finish', () async {
    final (client, server, tc, _) = muxPair();
    final recv = Completer<RelayStream>();
    server.incoming.listen(recv.complete);
    final s = client.open();
    final peer = await recv.future;
    final got = BytesBuilder(copy: false);
    final sub = peer.stream.listen(got.add);
    sub.pause();
    final data = pattern(600 << 10);
    s.add(data);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(s.pendingOut, data.length - muxInitialWindow);
    expect(got.length, 0);
    sub.resume();
    while (got.length < data.length) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(got.takeBytes(), data);
    expect(s.pendingOut, 0);
    expect(tc.sent[muxOpen], 1);
  });

  test('close: the peer reads buffered data then EOF, and done completes', () async {
    final (client, server, _, _) = muxPair();
    final recv = Completer<RelayStream>();
    server.incoming.listen(recv.complete);
    final s = client.open();
    s.add([9, 9]);
    await s.close();
    final peer = await recv.future;
    expect(await readAll(peer.stream), [9, 9]);
    await peer.done;
    await s.done;
    expect(() => s.add([1]), throwsStateError);
  });

  test('a peer that exceeds the window breaks the tunnel', () async {
    final (a, b) = MemoryMsgConn.pair();
    final client = RelayMux.client(PlainTransport(a));
    final s = client.open();
    expect(await b.read(), [muxOpen, 0, 0, 0, 1]);
    final frame = Uint8List(5 + muxMaxData)
      ..[0] = muxData
      ..[4] = 1;
    for (var i = 0; i <= muxInitialWindow ~/ muxMaxData; i++) {
      b.write(frame);
    }
    await client.done.timeout(const Duration(seconds: 2));
    expect(client.error, isA<RelayError>());
    expect(s.isClosed, isTrue);
  });

  test('the host closes OPENs beyond the stream limit', () async {
    final (client, server, _, _) = muxPair();
    final accepted = <RelayStream>[];
    server.incoming.listen(accepted.add);
    final streams = [for (var i = 0; i < muxMaxStreams + 1; i++) client.open()];
    await streams.last.done.timeout(const Duration(seconds: 2));
    expect(accepted, hasLength(muxMaxStreams));
    expect(streams.first.isClosed, isFalse);
  });

  test('a dropped tunnel ends every stream and refuses new ones', () async {
    final (client, server, _, _) = muxPair();
    server.incoming.listen((_) {});
    final s = client.open();
    final eof = readAll(s.stream);
    await server.close();
    await client.done.timeout(const Duration(seconds: 2));
    expect(await eof, isEmpty);
    expect(client.open, throwsA(isA<RelayError>()));
  });
}
