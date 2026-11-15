// Binary frames of an agentd attach stream (agentd `internal/proto/frame.go`):
// `[1 byte type][4 bytes big-endian length][payload]`.

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// Frame types (ASCII letters on the wire).
abstract final class FrameType {
  /// Terminal bytes, both directions.
  static const data = 0x44; // 'D'

  /// Client → daemon: uint16 cols, uint16 rows, big-endian.
  static const resize = 0x52; // 'R'

  /// Either side: detach / close.
  static const detach = 0x58; // 'X'

  /// Daemon → client: the session exited, payload = exit code as text.
  static const exit = 0x45; // 'E'

  /// Client → daemon: terminal-generated replies (query answers).
  static const auto = 0x41; // 'A'

  /// Client → daemon: 1 byte, 1 = focus gained, 0 = lost.
  static const focus = 0x46; // 'F'

  static bool isKnown(int t) => t == data || t == resize || t == detach || t == exit || t == auto || t == focus;
}

/// Frame header size: type + length.
const int frameHeaderSize = 5;

/// Largest payload the daemon accepts (`proto.MaxFrameSize`, 1 MiB).
const int maxFrameSize = 1 << 20;

/// One decoded frame.
class Frame {
  const Frame(this.type, this.payload);
  final int type;
  final Uint8List payload;
}

/// Encodes one frame. Payloads over [maxFrameSize] are rejected.
Uint8List encodeFrame(int type, [List<int> payload = const []]) {
  if (!FrameType.isKnown(type)) {
    throw AgentdTransportError('unknown frame type 0x${type.toRadixString(16)}');
  }
  if (payload.length > maxFrameSize) {
    throw const AgentdTransportError('frame too large');
  }
  final out = Uint8List(frameHeaderSize + payload.length);
  out[0] = type;
  ByteData.sublistView(out).setUint32(1, payload.length, Endian.big);
  out.setRange(frameHeaderSize, out.length, payload);
  return out;
}

/// Encodes [data] as one or more D frames of at most [maxFrameSize] bytes.
List<Uint8List> encodeData(List<int> data) {
  final out = <Uint8List>[];
  for (var i = 0; i < data.length; i += maxFrameSize) {
    final end = i + maxFrameSize < data.length ? i + maxFrameSize : data.length;
    out.add(encodeFrame(FrameType.data, data.sublist(i, end)));
  }
  return out;
}

/// The R payload: cols and rows as big-endian uint16, clamped to 1..65535.
Uint8List resizePayload(int cols, int rows) {
  final b = Uint8List(4);
  final bd = ByteData.sublistView(b);
  bd.setUint16(0, cols.clamp(1, 0xffff), Endian.big);
  bd.setUint16(2, rows.clamp(1, 0xffff), Endian.big);
  return b;
}

/// Decodes an R payload (zero dimensions are invalid, as in Go).
(int cols, int rows) parseResize(List<int> p) {
  if (p.length != 4) throw const AgentdTransportError('invalid resize frame');
  final bd = ByteData.sublistView(Uint8List.fromList(p));
  final cols = bd.getUint16(0, Endian.big);
  final rows = bd.getUint16(2, Endian.big);
  if (cols == 0 || rows == 0) throw const AgentdTransportError('invalid resize frame');
  return (cols, rows);
}

/// Decodes an E payload (decimal exit code, at most 12 bytes).
int parseExit(List<int> p) {
  if (p.isEmpty || p.length > 12) throw const AgentdTransportError('invalid exit frame');
  final code = int.tryParse(ascii.decode(p, allowInvalid: true).trim());
  if (code == null) throw const AgentdTransportError('invalid exit frame');
  return code;
}

/// Incremental frame decoder: feed chunks of any size, get whole frames.
/// Unknown types, oversized payloads and malformed R/E payloads throw
/// [AgentdTransportError] (the stream is then unusable, as in Go).
class FrameDecoder {
  final BytesBuilder _buf = BytesBuilder(copy: true);

  /// Bytes buffered of an incomplete frame.
  int get pendingLength => _buf.length;

  List<Frame> add(List<int> chunk) {
    if (chunk.isNotEmpty) _buf.add(chunk);
    final frames = <Frame>[];
    if (_buf.length < frameHeaderSize) return frames;
    final all = _buf.takeBytes();
    var off = 0;
    while (all.length - off >= frameHeaderSize) {
      final type = all[off];
      if (!FrameType.isKnown(type)) {
        throw AgentdTransportError('unknown frame type 0x${type.toRadixString(16)}');
      }
      final n = ByteData.sublistView(all, off + 1, off + frameHeaderSize).getUint32(0, Endian.big);
      if (n > maxFrameSize) throw const AgentdTransportError('frame too large');
      if (all.length - off - frameHeaderSize < n) break;
      final payload = Uint8List.fromList(Uint8List.sublistView(all, off + frameHeaderSize, off + frameHeaderSize + n));
      if (type == FrameType.resize) parseResize(payload);
      if (type == FrameType.exit) parseExit(payload);
      frames.add(Frame(type, payload));
      off += frameHeaderSize + n;
    }
    if (off < all.length) _buf.add(Uint8List.sublistView(all, off));
    return frames;
  }
}
