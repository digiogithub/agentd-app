// Pure Dart parser of tables inside chat text: Claude Code draws markdown
// tables as box-drawing text (light, heavy, double, rounded) and agents also
// emit plain markdown pipe tables. Anything inconsistent stays plain text.

/// A parsed table. [header] is null when the source had no header separator.
class ChatTable {
  const ChatTable({this.header, required this.rows});
  final List<String>? header;
  final List<List<String>> rows;

  int get columns => header?.length ?? (rows.isEmpty ? 0 : rows.first.length);

  /// Tab separated text (header first), for copying.
  String toText() => [
    if (header != null) header!.join('\t'),
    for (final r in rows) r.join('\t'),
  ].join('\n');

  @override
  bool operator ==(Object other) =>
      other is ChatTable &&
      _eq(header, other.header) &&
      rows.length == other.rows.length &&
      [for (var i = 0; i < rows.length; i++) _eq(rows[i], other.rows[i])]
          .every((e) => e);

  @override
  int get hashCode => Object.hash(header?.join('\u0001'), rows.length);

  static bool _eq(List<String>? a, List<String>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'ChatTable($header, $rows)';
}

sealed class ChatSegment {
  const ChatSegment();
}

class TextSegment extends ChatSegment {
  const TextSegment(this.text);
  final String text;
}

class TableSegment extends ChatSegment {
  const TableSegment(this.table);
  final ChatTable table;
}

const _vertical = '│┃║';
const _borderChars =
    '─━═┌┬┐├┼┤└┴┘┏┳┓┣╋┫┗┻┛╔╦╗╠╬╣╚╩╝╭╮╰╯┍┎┑┒┕┖┙┚┝┞┟┠┡┢┥┦┧┨┩┪┭┮┯┰┱┲┵┶┷┸┹┺┽┾┿╀╁╂╃╄╅╆╇╈╉╊╞╟╡╢╤╥╧╨╪╫';
const _junctions = '┬┼┴┳╋┻╦╬╩┯┰┷┸┿╂╤╥╧╨╪╫';
const _inner = '├┼┤┣╋┫╠╬╣┝┠┥┨╞╟╡╢╪╫┿╂'; // marks a separator between rows

enum _Kind { box, pipe, none }

class _Line {
  _Line(this.raw, this.body, this.kind, this.isBorder);
  final String raw;
  final String body; // without indentation and a leading ⏺
  final _Kind kind;
  final bool isBorder; // box border/separator, or pipe separator row
}

final _pipeSep = RegExp(r'^\s*:?-{1,}:?\s*$');

_Line _classify(String raw) {
  var s = raw.trimLeft();
  if (s.startsWith('⏺')) s = s.substring('⏺'.length).trimLeft();
  s = s.trimRight();
  if (s.isEmpty) return _Line(raw, s, _Kind.none, false);
  final first = s[0];
  if (_vertical.contains(first)) return _Line(raw, s, _Kind.box, false);
  if (_borderChars.contains(first)) {
    final ok = s.split('').every((c) => _borderChars.contains(c) || c == ' ');
    if (ok && s.length >= 2) return _Line(raw, s, _Kind.box, true);
    return _Line(raw, s, _Kind.none, false);
  }
  if (first == '|' && s.length >= 3) {
    final cells = _splitPipes(s);
    final sep = cells.isNotEmpty && cells.every(_pipeSep.hasMatch);
    return _Line(raw, s, _Kind.pipe, sep);
  }
  return _Line(raw, s, _Kind.none, false);
}

List<String> _splitPipes(String s) {
  var t = s.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|') && !t.endsWith(r'\|')) t = t.substring(0, t.length - 1);
  final out = <String>[];
  final b = StringBuffer();
  for (var i = 0; i < t.length; i++) {
    final c = t[i];
    if (c == r'\' && i + 1 < t.length && t[i + 1] == '|') {
      b.write('|');
      i++;
    } else if (c == '|') {
      out.add(b.toString());
      b.clear();
    } else {
      b.write(c);
    }
  }
  out.add(b.toString());
  return out;
}

/// Splits [text] into text and table segments. Text without any table comes
/// back as a single [TextSegment] holding the original string.
List<ChatSegment> parseChatSegments(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  final cls = [for (final l in lines) _classify(l)];
  if (!cls.any((l) => l.kind != _Kind.none)) return [TextSegment(text)];

  final out = <ChatSegment>[];
  final pending = <String>[];
  var anyTable = false;
  void flush() {
    while (pending.isNotEmpty && pending.last.trim().isEmpty) {
      pending.removeLast();
    }
    while (pending.isNotEmpty && pending.first.trim().isEmpty) {
      pending.removeAt(0);
    }
    if (pending.isNotEmpty) out.add(TextSegment(pending.join('\n')));
    pending.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final k = cls[i].kind;
    if (k == _Kind.none) {
      pending.add(lines[i]);
      i++;
      continue;
    }
    var j = i;
    while (j < lines.length && cls[j].kind == k) {
      j++;
    }
    final run = cls.sublist(i, j);
    final table = k == _Kind.box ? _parseBox(run) : _parsePipe(run);
    if (table == null) {
      pending.addAll(lines.sublist(i, j));
    } else {
      flush();
      out.add(TableSegment(table));
      anyTable = true;
    }
    i = j;
  }
  if (!anyTable) return [TextSegment(text)];
  flush();
  return out;
}

ChatTable? _parsePipe(List<_Line> run) {
  if (run.length < 2) return null;
  final rows = <List<String>>[];
  List<String>? header;
  for (var i = 0; i < run.length; i++) {
    final l = run[i];
    if (l.isBorder) {
      // Only valid directly after the first row.
      if (i != 1) return null;
      continue;
    }
    rows.add([for (final c in _splitPipes(l.body)) c.trim()]);
  }
  final hasSep = run.length > 1 && run[1].isBorder;
  if (!hasSep || rows.length < 2) {
    return null; // needs header + separator + body
  }
  final n = rows.first.length;
  if (n < 2 || rows.any((r) => r.length != n)) return null;
  header = rows.removeAt(0);
  return ChatTable(header: header, rows: rows);
}

List<int> _positions(String s, String set) => [
  for (var i = 0; i < s.length; i++)
    if (set.contains(s[i])) i,
];

List<String>? _cells(String body, List<int>? bounds) {
  if (bounds != null && bounds.length >= 2) {
    var ok = body.length > bounds.last;
    if (ok) {
      for (final b in bounds) {
        if (!_vertical.contains(body[b])) {
          ok = false;
          break;
        }
      }
    }
    if (ok) {
      return [
        for (var i = 0; i + 1 < bounds.length; i++)
          body.substring(bounds[i] + 1, bounds[i + 1]).trim(),
      ];
    }
  }
  var t = body;
  if (_vertical.contains(t[0])) t = t.substring(1);
  if (t.isNotEmpty && _vertical.contains(t[t.length - 1])) {
    t = t.substring(0, t.length - 1);
  }
  return t.split(RegExp('[$_vertical]')).map((c) => c.trim()).toList();
}

ChatTable? _parseBox(List<_Line> run) {
  // Column boundaries from the first border line with junctions.
  List<int>? bounds;
  for (final l in run) {
    if (l.isBorder && _positions(l.body, _junctions).isNotEmpty) {
      bounds = [
        ..._positions(l.body, '┌┍┎┏╔╒╓╭├┝┠┣╞╟╠'),
        ..._positions(l.body, _junctions),
        ..._positions(l.body, '┐┑┒┓╗╕╖╮┤┥┨┫╡╢╣'),
      ]..sort();
      break;
    }
  }

  // Groups of row lines, split by inner separators (├ ┼ ┤ lines).
  final groups = <List<List<String>>>[];
  var cur = <List<String>>[];
  var sawInner = false;
  var rowLines = 0;
  for (var i = 0; i < run.length; i++) {
    final l = run[i];
    if (l.isBorder) {
      final inner = _inner.contains(l.body[0]);
      if (!inner) {
        // Top or bottom border: only valid first / last.
        if (i != 0 && i != run.length - 1) return null;
        continue;
      }
      if (cur.isEmpty) return null; // separator with nothing above
      groups.add(cur);
      cur = [];
      sawInner = true;
      continue;
    }
    final cells = _cells(l.body, bounds);
    if (cells == null) return null;
    cur.add(cells);
    rowLines++;
  }
  if (cur.isNotEmpty) groups.add(cur);
  if (rowLines == 0) return null;

  final n = groups.first.first.length;
  if (n < 1) return null;
  for (final g in groups) {
    for (final r in g) {
      if (r.length != n) return null;
    }
  }

  List<String> merge(List<List<String>> g) => [
    for (var c = 0; c < n; c++)
      g.map((r) => r[c]).where((s) => s.isNotEmpty).join(' '),
  ];

  List<String>? header;
  final rows = <List<String>>[];
  if (sawInner && groups.length >= 2) {
    header = merge(groups.first);
    final body = groups.sublist(1);
    final bodySeparated =
        groups.length > 2 ||
        run.where((l) => l.isBorder && _inner.contains(l.body[0])).length > 1;
    if (bodySeparated) {
      for (final g in body) {
        rows.add(merge(g));
      }
    } else {
      rows.addAll(_continuations(body.expand((g) => g).toList(), n));
    }
  } else {
    // No separators at all: plain rows with continuation lines.
    rows.addAll(_continuations(groups.expand((g) => g).toList(), n));
  }
  if (rows.isEmpty) return null;
  return ChatTable(header: header, rows: rows);
}

/// Lines whose first cell is empty continue the previous row (cells wrapped
/// over several lines when the table has no separators between body rows).
List<List<String>> _continuations(List<List<String>> lines, int n) {
  final out = <List<String>>[];
  for (final l in lines) {
    final cont =
        out.isNotEmpty &&
        l.first.isEmpty &&
        n > 1 &&
        l.any((c) => c.isNotEmpty);
    if (cont) {
      final prev = out.last;
      for (var c = 0; c < n; c++) {
        if (l[c].isNotEmpty) {
          prev[c] = prev[c].isEmpty ? l[c] : '${prev[c]} ${l[c]}';
        }
      }
    } else {
      out.add([...l]);
    }
  }
  return out;
}
