// Message connections under the Noise layer: a WebSocket to agentd-relay in
// production, an in-memory pair in tests.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'wire.dart';

/// Largest WebSocket message accepted (the relay's own limit).
const relayReadLimit = 70 << 10;

/// Carries whole binary messages.
abstract class MsgConn {
  /// The next message, or null once the connection ended normally. Throws
  /// [RelayError] when it ended with a relay close code or broke.
  Future<Uint8List?> read();

  /// Queues one message (never blocks). Throws [RelayError] once closed
  /// locally; after the peer closed it is dropped ([read] reports why).
  void write(Uint8List msg);

  Future<void> close();
}

/// Turns a stream of messages into [MsgConn.read] calls.
class MsgInbox {
  final Queue<Uint8List> _q = Queue<Uint8List>();
  Completer<void>? _wait;
  bool _ended = false;
  Object? _error;

  void push(Uint8List m) {
    if (_ended) return;
    _q.add(m);
    _wake();
  }

  /// Ends the inbox; [error] (if any) is thrown by [read] after the queued
  /// messages.
  void end([Object? error]) {
    if (_ended) return;
    _ended = true;
    _error = error;
    _wake();
  }

  bool get ended => _ended;

  void _wake() {
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<Uint8List?> read() async {
    while (true) {
      if (_q.isNotEmpty) return _q.removeFirst();
      if (_ended) {
        final e = _error;
        if (e != null) throw e;
        return null;
      }
      await (_wait ??= Completer<void>()).future;
    }
  }
}

/// [MsgConn] over a dart:io WebSocket (binary messages only).
class WsMsgConn implements MsgConn {
  WsMsgConn(this.ws) {
    _sub = ws.listen(
      (m) {
        if (m is String) {
          _inbox.end(const RelayError(RelayFailure.protocol, 'unexpected text message'));
          unawaited(close());
          return;
        }
        final b = m is Uint8List ? m : Uint8List.fromList(m as List<int>);
        if (b.length > relayReadLimit) {
          _inbox.end(const RelayError(RelayFailure.protocol, 'message too large'));
          unawaited(close());
          return;
        }
        _inbox.push(b);
      },
      onError: (Object e) => _inbox.end(RelayError(RelayFailure.protocol, 'connection error (${e.runtimeType})')),
      onDone: () => _inbox.end(relayCloseError(ws.closeCode)),
      cancelOnError: true,
    );
  }

  final WebSocket ws;
  final MsgInbox _inbox = MsgInbox();
  late final StreamSubscription<dynamic> _sub;
  bool _closed = false;

  /// Opens a client tunnel to [route] through the relay at [base]
  /// (`/v1/connect`). The handshake is not run here.
  static Future<WsMsgConn> dialTunnel(
    String base,
    String route, {
    Duration timeout = const Duration(seconds: 15),
    Duration ping = const Duration(seconds: 25),
  }) async {
    final url = relayEndpoint(base, '/v1/connect', {'route': route});
    final WebSocket ws;
    try {
      ws = await WebSocket.connect(url, protocols: const [relaySubprotocol]).timeout(timeout);
    } on TimeoutException {
      throw const RelayError(RelayFailure.unreachable, 'the relay did not answer');
    } on HandshakeException {
      throw const RelayError(RelayFailure.unreachable, 'TLS handshake with the relay failed');
    } on SocketException {
      throw const RelayError(RelayFailure.unreachable, 'cannot reach the relay');
    } on WebSocketException {
      throw const RelayError(RelayFailure.unreachable, 'the relay refused the connection');
    } on HttpException {
      throw const RelayError(RelayFailure.unreachable, 'the relay refused the connection');
    }
    if (ws.protocol != relaySubprotocol) {
      unawaited(ws.close(1002));
      throw const RelayError(RelayFailure.unreachable, 'not an agentd relay (subprotocol)');
    }
    ws.pingInterval = ping;
    return WsMsgConn(ws);
  }

  @override
  Future<Uint8List?> read() => _inbox.read();

  @override
  void write(Uint8List msg) {
    if (_closed) throw const RelayError(RelayFailure.protocol, 'tunnel closed');
    if (ws.readyState != WebSocket.open) return;
    ws.add(msg);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _inbox.end();
    try {
      await ws.close(WebSocketStatus.normalClosure).timeout(const Duration(seconds: 3));
    } catch (_) {}
    await _sub.cancel();
  }
}

/// One end of an in-memory message pipe (tests, the fake host).
class MemoryMsgConn implements MsgConn {
  MemoryMsgConn._();

  late MemoryMsgConn _peer;
  final MsgInbox _inbox = MsgInbox();
  bool _closed = false;
  bool _peerGone = false;

  /// Close code the peer sees when this end closes with [closeWith].
  int? _closeCode;

  /// A connected pair.
  static (MemoryMsgConn, MemoryMsgConn) pair() {
    final a = MemoryMsgConn._();
    final b = MemoryMsgConn._();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  bool get isClosed => _closed;

  @override
  Future<Uint8List?> read() => _inbox.read();

  @override
  void write(Uint8List msg) {
    if (_closed) throw const RelayError(RelayFailure.protocol, 'tunnel closed');
    if (msg.length > relayReadLimit) throw const RelayError(RelayFailure.protocol, 'message too large');
    if (_peerGone) return;
    _peer._inbox.push(Uint8List.fromList(msg));
  }

  /// Closes with a relay close code (the peer's read throws its error).
  Future<void> closeWith(int code) async {
    _closeCode = code;
    await close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _inbox.end();
    _peer._inbox.end(relayCloseError(_closeCode));
    _peer._peerGone = true;
  }
}
