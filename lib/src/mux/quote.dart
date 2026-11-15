// POSIX shell quoting for the commands the mux and provision layers build.
// Kept private to these folders (the transport layer has its own copy) so
// the layers stay independent.

final _safe = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

/// Quotes [s] as one POSIX shell word. Safe words are returned unchanged.
String posixQuote(String s) {
  if (s.isEmpty) return "''";
  if (_safe.hasMatch(s)) return s;
  return "'${s.replaceAll("'", r"'\''")}'";
}

/// Quotes every element of [argv] and joins them with spaces.
String posixJoin(Iterable<String> argv) => argv.map(posixQuote).join(' ');

/// Quotes a directory path for the remote shell, keeping a leading `~` or
/// `~/` expandable (as `"$HOME"`).
String posixDir(String dir) {
  if (dir == '~') return r'"$HOME"';
  if (dir.startsWith('~/')) {
    final rest = dir.substring(2);
    return rest.isEmpty ? r'"$HOME"' : '"\$HOME"/${posixQuote(rest)}';
  }
  return posixQuote(dir);
}
