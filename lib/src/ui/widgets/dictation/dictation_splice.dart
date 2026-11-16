// Pure text-splicing for live dictation: a partial transcript is inserted at
// the cursor, replaced by each newer partial, and committed by the final one.

import 'package:flutter/services.dart' show TextEditingValue, TextSelection;

/// Where the dictated segment currently sits in the text.
class DictationSplice {
  DictationSplice._(this.before, this.after);

  /// Starts a dictation at the selection of [value] (the selection, if any,
  /// is replaced by the dictated text; with no valid selection: appended).
  factory DictationSplice.start(TextEditingValue value) {
    final t = value.text;
    var s = value.selection;
    if (!s.isValid) s = TextSelection.collapsed(offset: t.length);
    final a = s.start.clamp(0, t.length), b = s.end.clamp(0, t.length);
    return DictationSplice._(t.substring(0, a), t.substring(b));
  }

  /// Text before and after the dictated segment; both stay intact.
  final String before, after;

  /// The value to show for the heard [text]. The cursor ends right after the
  /// dictated words. An empty [text] yields the original text.
  TextEditingValue apply(String text) {
    final heard = text.trim();
    if (heard.isEmpty) {
      return TextEditingValue(
        text: before + after,
        selection: TextSelection.collapsed(offset: before.length),
      );
    }
    final lead = before.isNotEmpty && !_isSpace(before[before.length - 1])
        ? ' '
        : '';
    final trail = after.isNotEmpty && !_isSpace(after[0]) ? ' ' : '';
    final segment = '$lead$heard$trail';
    final cursor = before.length + lead.length + heard.length;
    return TextEditingValue(
      text: before + segment + after,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  static bool _isSpace(String c) => c.trim().isEmpty;
}
