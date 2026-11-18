// Harness guessing for multiplexer panes and session names. zellij and tmux
// know nothing about agents: the app infers the harness from the program
// running in a pane and from naming conventions.

/// Harness names the app recognises.
const knownHarnesses = <String>{
  'claude',
  'codex',
  'pando',
  'opencode',
  'gemini',
  'grok',
  'aider',
  'crush',
  'goose',
  'amp',
  'qwen',
  'cursor-agent',
};

final _versionLike = RegExp(r'^\d+\.\d+\.\d+');

/// Guesses the harness from a pane's program ([command]: tmux
/// `#{pane_current_command}`, zellij `terminal_command`, or a full command
/// line) and an optional [title] (pane title). Returns null when nothing
/// matches. `node` / `bun` alone are ambiguous (many harnesses are Node
/// programs) and only resolve through the title or the command line.
String? guessHarness(String? command, {String? title}) {
  for (final source in [command, title]) {
    final h = _fromCommandLine(source);
    if (h != null) return h;
  }
  // Claude Code's native installer runs ~/.local/share/claude/versions/X.Y.Z,
  // so tmux reports the version as the pane command.
  final c = command?.trim() ?? '';
  if (_versionLike.hasMatch(c) && !c.contains(' ')) return 'claude';
  return null;
}

String? _fromCommandLine(String? line) {
  if (line == null) return null;
  final words = line.trim().split(RegExp(r'\s+'));
  for (final w in words.take(4)) {
    if (w.isEmpty) continue;
    var base = w.split('/').last.toLowerCase();
    if (base.endsWith('.js') || base.endsWith('.mjs')) {
      base = base.substring(0, base.lastIndexOf('.'));
    }
    if (knownHarnesses.contains(base)) return base;
    // npm package paths: .../@anthropic-ai/claude-code/cli.js, @openai/codex
    if (w.contains('claude-code')) return 'claude';
    if (w.contains('@openai/codex')) return 'codex';
    if (w.contains('gemini-cli')) return 'gemini';
    if (w.contains('opencode')) return 'opencode';
    if (w.contains('/claude/versions/')) return 'claude';
  }
  return null;
}

/// Splits a session name that follows a harness convention into
/// (harness, project): agentd's `<harness>@<project>` (`codex@webapp`) or
/// `<harness>-<project>` (`claude-agentd`) when the prefix is a known
/// harness. Otherwise both are null.
({String? harness, String? project}) splitSessionName(String name) {
  final at = name.indexOf('@');
  if (at > 0 && at < name.length - 1) {
    return (harness: name.substring(0, at), project: name.substring(at + 1));
  }
  for (final h in knownHarnesses) {
    for (final sep in ['-', '_', '.']) {
      final p = '$h$sep';
      if (name.length > p.length && name.toLowerCase().startsWith(p)) {
        return (harness: h, project: name.substring(p.length));
      }
    }
  }
  if (knownHarnesses.contains(name.toLowerCase())) {
    return (harness: name.toLowerCase(), project: null);
  }
  return (harness: null, project: null);
}

/// Last path element of [path] (`/home/u/src/webapp` → `webapp`).
String? baseName(String? path) {
  if (path == null) return null;
  final p = path.trim().replaceAll(RegExp(r'/+$'), '');
  if (p.isEmpty) return null;
  return p.split('/').last;
}
