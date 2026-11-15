// One daemon connection over a ByteChannel: JSON lines, optionally switching
// to raw bytes after the first line (attach upgrade).

import 'dart:async';
import 'dart:typed_data';

import '../core/contracts.dart';
import 'codec.dart';
import 'errors.dart';

/// Reads a [ByteChannel] once and splits it into JSON lines ([lines]). With
/// [rawAfterFirstLine] only the first line is a JSON line: every byte after
/// it (including bytes that arrived in the same chunk) goes to [raw].
class WireConnection {
  WireConnection(this.channel, {this.rawAfterFirstLine = false, int lineLimit = maxLineBytes})
    : _decoder = LineDecoder(lineLimit: lineLimit) {
    _sub = channel.stream.listen(_onData, onError: _onError, onDone: _onDone, cancelOnError: false);
  }

  final ByteChannel channel;
  final bool rawAfterFirstLine;
  final LineDecoder _decoder;
  late final StreamSubscription<Uint8List> _sub;

  final StreamController<String> _lines = StreamController<String>();
  final StreamController<Uint8List> _raw = StreamController<Uint8List>();
  bool _isRaw = false;
  bool _closed = false;

  /// JSON lines as they arrive. Single subscription. Ends when the channel
  /// closes; protocol errors (line too long) are delivered as errors.
  Stream<String> get lines => _lines.stream;

  /// Bytes after the first line (only with [rawAfterFirstLine]).
  Stream<Uint8List> get raw => _raw.stream;

  void write(List<int> bytes) {
    if (_closed) throw const AgentdTransportError('connection closed');
    channel.add(bytes);
  }

  void _onData(Uint8List chunk) {
    if (_closed) return;
    if (_isRaw) {
      _raw.add(chunk);
      return;
    }
    try {
      final lines = _decoder.add(chunk, limit: rawAfterFirstLine ? 1 : null);
      for (final l in lines) {
        _lines.add(l);
      }
      if (rawAfterFirstLine && lines.isNotEmpty) {
        _isRaw = true;
        _lines.close();
        final rest = _decoder.takeRemainder();
        if (rest.isNotEmpty) _raw.add(rest);
      }
    } on AgentdTransportError catch (e) {
      _lines.addError(e);
      unawaited(close());
    }
  }

  void _onError(Object e, StackTrace st) {
    final err = AgentdTransportError('channel error', cause: e);
    if (_isRaw) {
      _raw.addError(err, st);
    } else {
      _lines.addError(err, st);
    }
  }

  void _onDone() {
    _closed = true;
    if (!_lines.isClosed) _lines.close();
    if (!_raw.isClosed) _raw.close();
  }

  /// Closes the channel and both streams.
  Future<void> close() async {
    if (_closed && _lines.isClosed && _raw.isClosed) return;
    _closed = true;
    await _sub.cancel();
    if (!_lines.isClosed) unawaited(_lines.close());
    if (!_raw.isClosed) unawaited(_raw.close());
    try {
      await channel.close();
    } catch (_) {
      // Closing an already broken channel is not an error for us.
    }
  }
}
