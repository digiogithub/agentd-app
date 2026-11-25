// A code block of the chat shown as normal text: the daemon sometimes marks
// prose as code (hard-wrapped, indented terminal text), and the reader can
// turn such a block back into wrapped paragraphs.

import 'package:material_ui/material_ui.dart';

/// Identifies a code block inside one session view: its first two lines, so
/// the choice survives view refreshes and a block that is still growing.
String codeBlockKey(String code) => code.split('\n').take(2).join('\n');

final _listItem = RegExp(r'^(?:[-*•] |\d+\. )');

/// [code] as prose: indentation trimmed, consecutive lines joined into one
/// paragraph (the terminal hard-wraps prose), a list item on its own line,
/// a blank line between paragraphs.
String codeAsProse(String code) {
  final out = StringBuffer();
  var open = false; // a line is being written
  var gap = false; // a blank line was seen since the last text
  for (final raw in code.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      gap = open || gap;
      open = false;
      continue;
    }
    if (out.isNotEmpty) {
      if (gap) {
        out.write('\n\n');
      } else if (!open || _listItem.hasMatch(line)) {
        out.write('\n');
      } else {
        out.write(' ');
      }
    }
    out.write(line);
    open = true;
    gap = false;
  }
  return out.toString();
}

/// The code blocks of one session view the reader turned into text
/// ([codeBlockKey]). In memory only.
class CodeBlockModes extends InheritedWidget {
  const CodeBlockModes({super.key, required this.asText, required super.child});
  final Set<String> asText;

  static Set<String>? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<CodeBlockModes>()?.asText;

  @override
  bool updateShouldNotify(CodeBlockModes oldWidget) => false;
}
