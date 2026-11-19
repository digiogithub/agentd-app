// Stream multiplexer inside the encrypted relay tunnel (protocol v1, Go
// internal/relaywire/mux.go). Each plaintext is one frame:
//
//     type u8 | stream u32 BE | payload
//
// 1 OPEN (client only, odd ids from 1), 2 DATA (<= 32 KiB), 3 CLOSE (full
// close: the peer reads what is buffered, then EOF), 4 CREDIT (u32 BE bytes
// the receiver lets the sender send more). Initial window 256 KiB per stream
// and direction; credit is granted once the application consumed >= 64 KiB.
//
// A [RelayStream] is a [ByteChannel], so the agentd client runs on it exactly
// as on an SSH direct-streamlocal channel. The host side ([RelayMux.server])
// is used by tests.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../core/contracts.dart';
import 'wire.dart';

const muxOpen = 1;
const muxData = 2;
const muxClose = 3;
const muxCredit = 4;

/// Largest DATA payload.
const muxMaxData = 32 << 10;

/// Initial credit per stream and direction.
const muxInitialWindow = 256 << 10;

/// Open streams per tunnel (the host closes OPENs beyond).
const muxMaxStreams = 64;

/// Credit is granted after the application consumed this much.
const muxGrantAfter = muxInitialWindow ~/ 4;

/// What a mux runs on: an established Noise transport over the relay.
abstract class MuxTransport {
  /// Next plaintext, or null at the end. May throw.
  Future<Uint8List?> recv();

  /// Encrypts and queues one plaintext (never blocks).
  void send(Uint8List plain);

  Future<void> close();
}

/// Multiplexes [RelayStream]s over one tunnel.
class RelayMux {
  RelayMux.client(this._t) : _client = true {
    unawaited(_loop());
  }

  RelayMux.server(this._t) : _client = false {
    unawaited(_loop());
  }

  final MuxTransport _t;
  final bool _client;
  final Map<int, RelayStream> _streams = {};
  final StreamController<RelayStream> _incoming = StreamController<RelayStream>();
  final Completer<void> _done = Completer<void>();
  int _nextId = 1;
  Object? _error;

  /// Completes when the tunnel ends.
  Future<void> get done => _done.future;

  bool get isClosed => _done.isCompleted;

  /// Why the tunnel ended (null while it is up or after a local [close]).
  Object? get error => _error;

  /// Streams the peer opened (host side).
  Stream<RelayStream> get incoming => _incoming.stream;

  /// Number of open streams.
  int get openStreams => _streams.length;

  /// Opens a stream (client side). Throws [RelayError] once the tunnel ended.
  RelayStream open() {
    if (!_client) throw StateError('only the client opens streams');
    if (isClosed) throw _error is RelayError ? _error as RelayError : const RelayError(RelayFailure.protocol, 'tunnel closed');
    final id = _nextId;
    _nextId += 2;
    final s = RelayStream._(this, id);
    _streams[id] = s;
    _send(muxOpen, id);
    return s;
  }

  /// Ends the tunnel and every stream.
  Future<void> close() async {
    _fail(null);
  }

  void _fail(Object? err) {
    if (_done.isCompleted) return;
    _error = err;
    final streams = [..._streams.values];
    _streams.clear();
    for (final s in streams) {
      s._remoteClosed();
    }
    unawaited(_incoming.close());
    _done.complete();
    unawaited(_t.close().catchError((Object _) {}));
  }

  bool _send(int type, int id, [List<int>? payload]) {
    if (_done.isCompleted) return false;
    final n = payload?.length ?? 0;
    final b = Uint8List(5 + n);
    b[0] = type;
    b.buffer.asByteData().setUint32(1, id);
    if (payload != null) b.setAll(5, payload);
    try {
      _t.send(b);
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  Future<void> _loop() async {
    while (!_done.isCompleted) {
      Uint8List? b;
      try {
        b = await _t.recv();
      } catch (e) {
        _fail(e);
        return;
      }
      if (b == null) {
        _fail(const RelayError(RelayFailure.protocol, 'tunnel closed'));
        return;
      }
      if (_done.isCompleted) return;
      if (b.length < 5) {
        _fail(const RelayError(RelayFailure.protocol, 'short mux frame'));
        return;
      }
      final type = b[0];
      final id = ByteData.sublistView(b, 1, 5).getUint32(0);
      final payload = Uint8List.sublistView(b, 5);
      final s = _streams[id];
      switch (type) {
        case muxOpen:
          if (_client || id.isEven || s != null) {
            _fail(const RelayError(RelayFailure.protocol, 'bad OPEN'));
            return;
          }
          if (_streams.length >= muxMaxStreams || !_incoming.hasListener) {
            _send(muxClose, id);
            continue;
          }
          final ns = RelayStream._(this, id);
          _streams[id] = ns;
          _incoming.add(ns);
        case muxData:
          if (s == null) continue; // closed locally; data in flight
          if (!s._push(payload)) {
            _fail(const RelayError(RelayFailure.protocol, 'peer exceeded the stream window'));
            return;
          }
        case muxClose:
          if (s != null) {
            _streams.remove(id);
            s._remoteClosed();
          }
        case muxCredit:
          if (s != null && payload.length == 4) s._addCredit(ByteData.sublistView(payload).getUint32(0));
        default:
          _fail(const RelayError(RelayFailure.protocol, 'unknown mux frame'));
          return;
      }
    }
  }
}

/// One bidirectional byte stream of a tunnel: one daemon connection.
class RelayStream implements ByteChannel {
  RelayStream._(this._m, this.id) {
    _out = StreamController<Uint8List>(onListen: _pump, onResume: _pump, onCancel: _onCancel);
  }

  final RelayMux _m;
  final int id;
  late final StreamController<Uint8List> _out;
  final Completer<void> _done = Completer<void>();

  // Inbound: undelivered chunks, bytes the peer may still send, bytes
  // delivered since the last CREDIT.
  final Queue<Uint8List> _inq = Queue<Uint8List>();
  int _window = muxInitialWindow;
  int _consumed = 0;

  // Outbound: bytes waiting for credit, credit left.
  final Queue<Uint8List> _outq = Queue<Uint8List>();
  int _credit = muxInitialWindow;

  bool _rclosed = false;
  bool _lclosed = false;
  bool _closeSent = false;

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  Future<void> get done => _done.future;

  bool get isClosed => _lclosed || _rclosed;

  /// Bytes queued for sending, waiting for credit.
  int get pendingOut => _outq.fold(0, (n, b) => n + b.length);

  @override
  void add(List<int> data) {
    if (_lclosed) throw StateError('relay stream closed');
    if (_rclosed || data.isEmpty) return; // the peer is gone: nothing can arrive
    _outq.add(data is Uint8List ? Uint8List.fromList(data) : Uint8List.fromList(data));
    _flush();
  }

  void _flush() {
    while (_credit > 0 && _outq.isNotEmpty && !_rclosed) {
      final head = _outq.first;
      var n = head.length;
      if (n > _credit) n = _credit;
      if (n > muxMaxData) n = muxMaxData;
      if (!_m._send(muxData, id, Uint8List.sublistView(head, 0, n))) return;
      _credit -= n;
      if (n == head.length) {
        _outq.removeFirst();
      } else {
        _outq
          ..removeFirst()
          ..addFirst(Uint8List.sublistView(head, n));
      }
    }
    if (_lclosed && _outq.isEmpty && !_closeSent) _sendClose();
  }

  void _sendClose() {
    _closeSent = true;
    if (!_rclosed) {
      _m._streams.remove(id);
      _m._send(muxClose, id);
    }
  }

  void _addCredit(int n) {
    _credit += n;
    _flush();
  }

  bool _push(Uint8List p) {
    if (_lclosed) return true;
    _window -= p.length;
    if (_window < 0) return false;
    _inq.add(Uint8List.fromList(p));
    _pump();
    return true;
  }

  void _pump() {
    while (_inq.isNotEmpty && _out.hasListener && !_out.isPaused && !_out.isClosed) {
      final c = _inq.removeFirst();
      _out.add(c);
      _consumed += c.length;
    }
    if (_consumed >= muxGrantAfter && !_rclosed && !_lclosed) {
      final grant = _consumed;
      _consumed = 0;
      _window += grant;
      final p = Uint8List(4)..buffer.asByteData().setUint32(0, grant);
      _m._send(muxCredit, id, p);
    }
    if (_rclosed && _inq.isEmpty && !_out.isClosed) {
      unawaited(_out.close());
    }
  }

  void _remoteClosed() {
    if (_rclosed) return;
    _rclosed = true;
    _outq.clear();
    _m._streams.remove(id);
    if (!_done.isCompleted) _done.complete();
    _pump();
  }

  void _onCancel() {
    _inq.clear();
  }

  /// Closes both directions. Bytes still waiting for credit are sent first
  /// (CLOSE follows them), as a Go Write would have blocked until sent; data
  /// arriving afterwards is discarded.
  @override
  Future<void> close() async {
    if (_lclosed) return;
    _lclosed = true;
    _inq.clear();
    if (!_out.isClosed) unawaited(_out.close());
    if (!_done.isCompleted) _done.complete();
    _flush();
  }
}
