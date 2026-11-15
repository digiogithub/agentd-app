// Newline-delimited JSON codec of the agentd daemon protocol (agentd
// AGENTS.md, "Wire protocol"): requests `{"op", "args"}`, answers
// `{"ok": true, "data"}` / `{"ok": false, "error", "code", "data"?}`.

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// Upper bound of one JSON line, as the daemon's `proto.MaxLineSize` (8 MiB).
const int maxLineBytes = 8 << 20;

/// Splits a byte stream into lines on `\n` (a trailing `\r` is dropped).
/// Lines are kept as bytes until complete, so a UTF-8 sequence split across
/// chunks decodes correctly. A line longer than [lineLimit] is an error.
class LineDecoder {
  LineDecoder({this.lineLimit = maxLineBytes});

  final int lineLimit;
  final BytesBuilder _pending = BytesBuilder(copy: true);

  /// Bytes received after the last complete line.
  int get pendingLength => _pending.length;

  /// Feeds [chunk] and returns the complete lines it ends. With [limit] at
  /// most that many lines are returned and everything after the last one
  /// stays pending untouched (see [takeRemainder]): used when the
  /// connection switches to another framing after its first line.
  List<String> add(List<int> chunk, {int? limit}) {
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (limit != null && lines.length >= limit) break;
      if (chunk[i] != 0x0a) continue;
      final segment = i - start;
      if (_pending.length + segment > lineLimit) {
        throw const AgentdTransportError('line too long');
      }
      _pending.add(chunk.sublist(start, i));
      lines.add(_decode(_pending.takeBytes()));
      start = i + 1;
    }
    if (start < chunk.length) {
      _pending.add(chunk.sublist(start));
    }
    final limited = limit != null && lines.length >= limit;
    if (!limited && _pending.length > lineLimit) {
      throw const AgentdTransportError('line too long');
    }
    return lines;
  }

  /// Returns and clears the pending bytes (the start of a binary stream
  /// after an upgrade).
  Uint8List takeRemainder() => _pending.takeBytes();

  static String _decode(Uint8List bytes) {
    var end = bytes.length;
    if (end > 0 && bytes[end - 1] == 0x0d) end--;
    return utf8.decode(Uint8List.sublistView(bytes, 0, end), allowMalformed: true);
  }
}

/// Encodes one request line. Null [args] are omitted (the daemon treats
/// absent args as empty). Throws [AgentdTransportError] past [maxLineBytes].
Uint8List encodeRequest(String op, [Map<String, Object?>? args]) {
  final req = <String, Object?>{'op': op};
  if (args != null) req['args'] = args;
  final bytes = utf8.encode('${jsonEncode(req)}\n');
  if (bytes.length > maxLineBytes) {
    throw const AgentdTransportError('request too large');
  }
  return bytes;
}

/// Decodes one answer line: returns `data` (null when absent) or throws
/// [AgentdError] for `ok: false` and [AgentdTransportError] when the line is
/// not a daemon answer.
Object? decodeResponse(String line, {String? op}) {
  final Object? v;
  try {
    v = jsonDecode(line);
  } on FormatException catch (e) {
    throw AgentdTransportError('invalid json from daemon', cause: e);
  }
  if (v is! Map<String, Object?> || v['ok'] is! bool) {
    throw const AgentdTransportError('not a daemon response');
  }
  if (v['ok'] == true) return v['data'];
  final err = v['error'];
  final code = v['code'];
  throw AgentdError(err is String && err.isNotEmpty ? err : 'unknown error', code: code is String ? code : '', data: v['data'], op: op);
}

/// Drops nulls and empty/false optional values so args mirror the Go
/// structs' `omitempty` tags. Required keys are kept as given.
Map<String, Object?> compactArgs(Map<String, Object?> args, {Set<String> keep = const {}}) {
  final out = <String, Object?>{};
  args.forEach((k, v) {
    if (keep.contains(k)) {
      out[k] = v;
      return;
    }
    if (v == null || v == false || v == '' || v == 0) return;
    if (v is Iterable && v.isEmpty) return;
    if (v is Map && v.isEmpty) return;
    out[k] = v;
  });
  return out;
}
