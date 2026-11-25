// Pure text helpers of the Android Auto client: what is read aloud (an
// agent's conclusion, the last lines of a session) and how a dictated answer
// is matched to the options of a question or a terminal menu.

import '../core/contracts.dart';

/// Longest text handed to the text-to-speech engine or a car template.
const kCarSpeakLimit = 1200;

/// The agent's last message: the text of the last agent item, or of the last
/// item at all when the agent wrote nothing yet. Null without items.
String? conclusionOf(List<ChatItem> items) {
  for (final it in items.reversed) {
    if (it.role == ChatRole.agent && it.text.trim().isNotEmpty) return it.text.trim();
  }
  return null;
}

/// The last [n] non-blank lines of the session, as the chat shows them
/// (prompts, agent text, tool calls with their first output line).
List<String> lastLinesOf(List<ChatItem> items, int n) {
  final lines = <String>[];
  for (final it in items) {
    switch (it.role) {
      case ChatRole.user:
        lines.addAll(_lines(it.text).map((l) => '> $l'));
      case ChatRole.agent:
        lines.addAll(_lines(it.text).where((l) => l != kChatCodeFence));
      case ChatRole.tool:
        final head = [it.title, if (it.meta != null && it.meta!.isNotEmpty) it.meta].whereType<String>().join(': ');
        if (head.isNotEmpty) lines.add(head);
      case ChatRole.system:
        lines.addAll(_lines(it.text));
    }
  }
  return lines.length <= n ? lines : lines.sublist(lines.length - n);
}

Iterable<String> _lines(String text) => text.split('\n').map((l) => l.trimRight()).where((l) => l.trim().isNotEmpty);

/// Chat markup turned into something worth hearing: code blocks and tables
/// are named instead of read, markdown marks and box drawing removed, one
/// line per sentence, cut at [limit] characters on a word boundary.
String speakable(String text, {int limit = kCarSpeakLimit}) {
  final out = <String>[];
  var inCode = false;
  var codeSaid = false;
  var tableSaid = false;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line == kChatCodeFence || line.startsWith('```')) {
      inCode = !inCode;
      if (inCode && !codeSaid) {
        out.add('(bloque de código)');
        codeSaid = true;
      }
      continue;
    }
    if (inCode) continue;
    if (_isTableLine(line)) {
      if (!tableSaid) out.add('(tabla)');
      tableSaid = true;
      continue;
    }
    tableSaid = false;
    codeSaid = false;
    final clean = line
        .replaceAll(RegExp(r'^[⏺●•\-*>#]+\s*'), '')
        .replaceAll(RegExp(r'\*\*|__|`'), '')
        .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1')
        .replaceAll(RegExp(r'https?://\S+'), 'un enlace')
        .trim();
    if (clean.isNotEmpty) out.add(clean);
  }
  return truncateWords(out.join('\n'), limit);
}

bool _isTableLine(String l) {
  if (l.isEmpty) return false;
  if (RegExp(r'^[│┃║├┝┠┣╞╟╠└┕┗╘╚┌┍┏╒╔╭╰─━═┼┬┴]').hasMatch(l)) return true;
  return l.startsWith('|') && l.endsWith('|');
}

/// [text] cut at [limit] characters on a word boundary, with an ellipsis.
String truncateWords(String text, int limit) {
  if (text.length <= limit) return text;
  var cut = text.substring(0, limit);
  final sp = cut.lastIndexOf(RegExp(r'\s'));
  if (sp > limit ~/ 2) cut = cut.substring(0, sp);
  return '${cut.trimRight()}…';
}

/// Lower case, no accents, punctuation as spaces, single spaces.
String normalizeSpoken(String s) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñç';
  const to = 'aaaaeeeeiiiioooouuuunc';
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    final c = String.fromCharCode(r);
    final i = from.indexOf(c);
    b.write(i >= 0 ? to[i] : c);
  }
  return b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

const _ordinals = <String, int>{
  'uno': 1, 'una': 1, 'primero': 1, 'primera': 1, 'one': 1, 'first': 1,
  'dos': 2, 'segundo': 2, 'segunda': 2, 'two': 2, 'second': 2,
  'tres': 3, 'tercero': 3, 'tercera': 3, 'three': 3, 'third': 3,
  'cuatro': 4, 'cuarto': 4, 'cuarta': 4, 'four': 4,
  'cinco': 5, 'quinto': 5, 'quinta': 5, 'five': 5,
  'seis': 6, 'sexto': 6, 'sexta': 6, 'six': 6,
  'siete': 7, 'septimo': 7, 'septima': 7, 'seven': 7,
  'ocho': 8, 'octavo': 8, 'octava': 8, 'eight': 8,
  'nueve': 9, 'noveno': 9, 'novena': 9, 'nine': 9,
};

const _yesWords = {'si', 'vale', 'ok', 'okay', 'adelante', 'aprueba', 'apruebalo', 'acepta', 'aceptar', 'permite', 'permitir', 'yes', 'claro', 'de acuerdo', 'hazlo', 'sigue', 'continua'};
const _noWords = {'no', 'rechaza', 'rechazar', 'deniega', 'denegar', 'cancela', 'cancelar', 'para', 'nunca', 'no lo hagas'};
const _yesLabels = ['yes', 'si', 'allow', 'approve', 'accept', 'ok', 'continue', 'proceed'];
const _noLabels = ['no', 'deny', 'reject', 'cancel', 'decline', 'abort'];

/// Which of [options] a dictated answer names, or null when it names none
/// (or more than one). Accepts the option's number ("2", "dos", "la
/// segunda", "opción dos"), a yes / no answer when the options are a yes /
/// no pair, and the option's label or a distinctive part of it.
int? matchSpokenOption(String spoken, List<String> options) {
  if (options.isEmpty) return null;
  final s = normalizeSpoken(spoken);
  if (s.isEmpty) return null;
  final labels = [for (final o in options) normalizeSpoken(o)];

  // Exact label first ("no" is both a label and a no-word).
  final exact = [for (final (i, l) in labels.indexed) if (l == s) i];
  if (exact.length == 1) return exact.first;

  // The number of the option, alone or leading ("uno", "dos, la de
  // mantenimiento"): dictation often adds the label after the number.
  final words = s.split(' ');
  final filler = {'la', 'el', 'opcion', 'numero', 'option', 'number', 'the', 'elijo', 'escoge', 'elige', 'quiero'};
  final rest = words.where((w) => !filler.contains(w)).toList();
  if (rest.isNotEmpty) {
    final n = int.tryParse(rest.first) ?? _ordinals[rest.first];
    if (n != null && rest.length == 1) return n >= 1 && n <= options.length ? n - 1 : null;
    // A digit first ("1 sí suena") names the option whatever follows.
    if (int.tryParse(rest.first) case final d? when d >= 1 && d <= options.length) return d - 1;
    // A number word followed by words of that same option ("uno, sí la veo").
    if (n != null && n >= 1 && n <= options.length && _hasWords(labels[n - 1], rest.skip(1).join(' '))) return n - 1;
  }

  // Yes / no.
  int? firstStarting(List<String> prefixes) {
    for (final (i, l) in labels.indexed) {
      final w = l.split(' ').first;
      if (prefixes.contains(w)) return i;
    }
    return null;
  }

  final saysYes = _yesWords.contains(s) || (words.first == 'si' && words.length <= 3);
  final saysNo = _noWords.contains(s) || (words.first == 'no' && words.length <= 3);
  if (saysYes && !saysNo) {
    final i = firstStarting(_yesLabels);
    if (i != null) return i;
  }
  if (saysNo && !saysYes) {
    final i = firstStarting(_noLabels);
    if (i != null) return i;
  }

  // The label contains what was said, or the other way round, word for
  // word ("no" is not inside "uno").
  if (s.length >= 3) {
    final hits = <int>{
      for (final (i, l) in labels.indexed)
        if (l.isNotEmpty && (_hasWords(l, s) || _hasWords(s, l))) i,
    };
    if (hits.length == 1) return hits.first;
    // Both: the longest label said wins ("si la veo" over "si").
    final full = [for (final i in hits) if (_hasWords(s, labels[i])) i]..sort((a, b) => labels[b].length - labels[a].length);
    if (full.length > 1 && labels[full[0]].length > labels[full[1]].length) return full[0];
  }
  return null;
}

/// Whether [text] holds [part] as whole words.
bool _hasWords(String text, String part) => ' $text '.contains(' $part ');

/// Options as they are read aloud: "1, Sí. 2, No."
String spokenOptions(List<String> options) => [for (final (i, o) in options.indexed) '${i + 1}, ${o.trim()}.'].join(' ');
