// POSIX shell quoting shared by every layer that builds remote commands.

/// Quotes [value] as one POSIX shell word using single quotes.
///
/// Every character keeps its literal meaning inside single quotes except the
/// single quote itself, which is written as `'\''` (close, escaped quote,
/// reopen). The empty string becomes `''`. Words made only of characters that
/// are never special to the shell are returned unquoted, so generated
/// commands stay readable when they are shown to the user.
String shellQuote(String value) {
  if (value.isEmpty) return "''";
  if (_safe.hasMatch(value)) return value;
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// Quotes every element of [argv] and joins them with spaces.
String shellJoin(Iterable<String> argv) => argv.map(shellQuote).join(' ');

final _safe = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');
