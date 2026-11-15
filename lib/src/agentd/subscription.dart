// A resilient `subscribe` stream: one connection per attempt, reconnecting
// with `since_seq` + `epoch` so the daemon replays what was missed (or
// answers `resync` when it cannot).

import 'dart:async';
import 'dart:convert';

import '../core/contracts.dart';
import 'codec.dart';
import 'errors.dart';
import 'events.dart';
import 'models.dart';
import 'wire.dart';

/// Live event stream of op `subscribe`. Listen to [events]; cancel the
/// listen or call [close] to stop. While [reconnect] is on, a lost stream
/// emits [DisconnectedEvent] and reconnects with exponential backoff; each
/// connection starts with a [SubscribedEvent] (fresh session snapshot).
///
/// The caller must reload its state (sessions, views) on [ResyncEvent] and
/// on a [SubscribedEvent] with `epochChanged` or without `resumed`.
class AgentdSubscription {
  AgentdSubscription(
    this._dial, {
    this.sessions = const [],
    this.kinds = const [],
    this.heartbeatMs,
    this.reconnect = true,
    int sinceSeq = 0,
    this._epoch,
    this.minBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 30),
    this.idleTimeout,
  }) : _lastSeq = sinceSeq {
    _out = StreamController<AgentdEvent>(onListen: _start, onCancel: close);
  }

  final Future<ByteChannel> Function() _dial;
  final List<String> sessions;
  final List<String> kinds;
  final int? heartbeatMs;
  final bool reconnect;
  final Duration minBackoff;
  final Duration maxBackoff;

  /// Silence after which the connection is considered dead. Default: three
  /// heartbeat periods (the daemon's default heartbeat is 15 s).
  final Duration? idleTimeout;

  late final StreamController<AgentdEvent> _out;
  WireConnection? _conn;
  Timer? _watchdog;
  Completer<void>? _sleep;
  bool _closed = false;
  bool _started = false;

  int _lastSeq;
  String? _epoch;

  /// Events (single subscription).
  Stream<AgentdEvent> get events => _out.stream;

  /// Last bus seq seen (pass it back with [epoch] to resume later).
  int get lastSeq => _lastSeq;

  /// Daemon epoch the seqs belong to (null before the first connection).
  String? get epoch => _epoch;

  Duration get _idle => idleTimeout ?? Duration(milliseconds: 3 * (heartbeatMs ?? 15000) + 5000);

  void _start() {
    if (_started) return;
    _started = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    var attempt = 0;
    var connectedBefore = false;
    while (!_closed) {
      Object? error;
      var fatal = false;
      var sawBye = false;
      try {
        await _connectOnce(connectedBefore, () {
          attempt = 0;
          connectedBefore = true;
        }, (bye) => sawBye = bye);
      } on AgentdError catch (e) {
        error = e;
        fatal = e.code == AgentdErrorCode.invalid || e.code == AgentdErrorCode.forbidden;
      } catch (e) {
        error = e;
      }
      if (_closed) break;
      if (!reconnect || fatal) {
        if (error != null && !_out.isClosed) _out.addError(error);
        await close();
        break;
      }
      var delay = minBackoff * (1 << (attempt < 16 ? attempt : 16));
      if (delay > maxBackoff) delay = maxBackoff;
      if (sawBye && delay < minBackoff * 2) delay = minBackoff * 2;
      attempt++;
      _emit(DisconnectedEvent(error: error, retryIn: delay));
      final sleep = _sleep = Completer<void>();
      final t = Timer(delay, () {
        if (!sleep.isCompleted) sleep.complete();
      });
      await sleep.future;
      t.cancel();
    }
  }

  /// Runs one connection until it ends. Returns whether it got its OK line.
  /// Throws on a failed dial, a daemon error answer or a protocol error.
  Future<bool> _connectOnce(bool connectedBefore, void Function() onConnected, void Function(bool) onBye) async {
    final ch = await _dial();
    if (_closed) {
      await ch.close();
      return false;
    }
    final conn = _conn = WireConnection(ch);
    final resumed = _lastSeq > 0 && _epoch != null && _epoch!.isNotEmpty;
    final args = compactArgs({
      'sessions': sessions,
      'kinds': kinds,
      'since_seq': resumed ? _lastSeq : null,
      'epoch': resumed ? _epoch : null,
      'heartbeat_ms': heartbeatMs,
    });
    final ended = Completer<bool>();
    var gotResult = false;
    void fail(Object e) {
      if (!ended.isCompleted) ended.completeError(e);
    }

    void arm() {
      _watchdog?.cancel();
      _watchdog = Timer(_idle, () {
        fail(const AgentdTransportError('subscribe: no event within the idle timeout'));
        unawaited(conn.close());
      });
    }

    final sub = conn.lines.listen(
      (line) {
        arm();
        try {
          if (!gotResult) {
            final data = decodeResponse(line, op: 'subscribe');
            final result = AgentdSubscribeResult.fromJson(jsonMap(data));
            final epochChanged = _epoch != null && _epoch!.isNotEmpty && result.epoch != _epoch;
            if (!resumed || epochChanged) _lastSeq = result.seq;
            _epoch = result.epoch;
            gotResult = true;
            onConnected();
            _emit(
              SubscribedEvent(result: result, reconnect: connectedBefore, resumed: resumed && !epochChanged, epochChanged: epochChanged),
            );
            return;
          }
          final ev = AgentdEvent.parse(jsonMap(jsonDecode(line)));
          if (ev is HelloEvent && ev.helloEpoch.isNotEmpty) _epoch = ev.helloEpoch;
          if (ev.seq != 0) {
            if (ev.seq <= _lastSeq) return; // duplicate (replay overlap)
            _lastSeq = ev.seq;
          }
          _emit(ev);
          if (ev is ByeEvent) {
            onBye(true);
            if (!ended.isCompleted) ended.complete(true);
            unawaited(conn.close());
          }
        } on AgentdError catch (e) {
          fail(e);
          unawaited(conn.close());
        } on FormatException catch (e) {
          fail(AgentdTransportError('invalid event line', cause: e));
          unawaited(conn.close());
        } on AgentdTransportError catch (e) {
          fail(e);
          unawaited(conn.close());
        }
      },
      onError: (Object e) => fail(e),
      onDone: () {
        if (!ended.isCompleted) {
          if (gotResult) {
            ended.complete(true);
          } else {
            ended.completeError(const AgentdTransportError('subscribe: connection closed before the answer'));
          }
        }
      },
    );
    try {
      conn.write(encodeRequest('subscribe', args));
      arm();
      return await ended.future;
    } finally {
      _watchdog?.cancel();
      _watchdog = null;
      await sub.cancel();
      await conn.close();
      if (identical(_conn, conn)) _conn = null;
    }
  }

  void _emit(AgentdEvent ev) {
    if (!_out.isClosed) _out.add(ev);
  }

  /// Stops the subscription and closes its connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _watchdog?.cancel();
    final s = _sleep;
    if (s != null && !s.isCompleted) s.complete();
    final c = _conn;
    _conn = null;
    if (c != null) await c.close();
    if (!_out.isClosed) unawaited(_out.close());
  }
}
