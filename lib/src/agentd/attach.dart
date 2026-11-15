// PtySession over an agentd attach stream (binary frames after the attach
// OK line; agentd AGENTS.md, "Wire protocol").

import 'dart:async';
import 'dart:typed_data';

import '../core/contracts.dart';
import 'errors.dart';
import 'frames.dart';
import 'wire.dart';

/// An attached agentd session. [stream] carries the terminal output (the
/// first chunk is the full redraw); [add] types (D frames), [resize] sends R,
/// [close] detaches (X) without stopping the session. [exitCode] completes
/// with the code of an E frame, or null when the stream ends without one.
class AgentdPtySession implements PtySession {
  AgentdPtySession(this._conn, {this.observe = false}) {
    _sub = _conn.raw.listen(_onBytes, onError: _onError, onDone: _onDone);
  }

  final WireConnection _conn;

  /// Watch-only attach: the daemon ignores input, resize and focus frames.
  final bool observe;

  final FrameDecoder _decoder = FrameDecoder();
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  final Completer<int?> _exit = Completer<int?>();
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<Uint8List> _sub;
  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  /// Sends terminal input (split into D frames of at most 1 MiB).
  @override
  void add(List<int> data) {
    if (_closed || data.isEmpty) return;
    for (final f in encodeData(data)) {
      _write(f);
    }
  }

  @override
  void resize(int cols, int rows) {
    if (_closed || cols <= 0 || rows <= 0) return;
    _write(encodeFrame(FrameType.resize, resizePayload(cols, rows)));
  }

  /// Sends terminal-generated replies (query answers) as an A frame: written
  /// to the child unchanged, never counted as human input.
  void addAutomatic(List<int> data) {
    if (_closed || data.isEmpty) return;
    _write(encodeFrame(FrameType.auto, data));
  }

  /// Reports window focus (F frame).
  void focus(bool gained) {
    if (_closed) return;
    _write(encodeFrame(FrameType.focus, [gained ? 1 : 0]));
  }

  /// Detaches (X frame) and closes the channel. The session keeps running.
  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      _conn.write(encodeFrame(FrameType.detach));
    } catch (_) {
      // The channel may already be gone.
    }
    await _finish();
  }

  void _write(Uint8List frame) {
    try {
      _conn.write(frame);
    } on AgentdTransportError {
      unawaited(_finish());
    }
  }

  void _onBytes(Uint8List chunk) {
    final List<Frame> frames;
    try {
      frames = _decoder.add(chunk);
    } on AgentdTransportError catch (e) {
      _onError(e);
      return;
    }
    for (final f in frames) {
      switch (f.type) {
        case FrameType.data:
          if (!_out.isClosed && f.payload.isNotEmpty) _out.add(f.payload);
        case FrameType.exit:
          if (!_exit.isCompleted) _exit.complete(parseExit(f.payload));
          unawaited(_finish());
          return;
        case FrameType.detach:
          unawaited(_finish());
          return;
        default:
          // R/A/F are client → daemon only: ignore.
          break;
      }
    }
  }

  void _onError(Object e, [StackTrace? st]) {
    if (!_out.isClosed) _out.addError(e, st);
    unawaited(_finish());
  }

  void _onDone() => unawaited(_finish());

  Future<void> _finish() async {
    if (_closed) return;
    _closed = true;
    if (!_exit.isCompleted) _exit.complete(null);
    await _sub.cancel();
    await _conn.close();
    if (!_out.isClosed) unawaited(_out.close());
    if (!_done.isCompleted) _done.complete();
  }
}
