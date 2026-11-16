// Folder listing of a host: one POSIX sh script run over the host shell and
// a pure parser of its NUL-separated output.
//
// Output: `@@agentd-ls NUL path NUL home NUL (name NUL flag NUL)*` where flag
// is `1` when the folder is readable and traversable, `0` otherwise; a final
// record with an empty name and flag `T` says the listing was capped.
// Exit codes: 3 = no such directory, 4 = no permission.

import '../core/contracts.dart';
import '../mux/quote.dart';

/// Folders returned at most.
const listDirCap = 2000;

const _marker = '@@agentd-ls';

/// The script for [path] (absolute; empty = `$HOME`). The path is
/// single-quoted, never interpolated into code.
String listDirScript(String path, {bool hidden = false, int cap = listDirCap}) {
  final p = path.isEmpty ? "''" : posixQuote(path);
  return '''
p=$p
h=${hidden ? 1 : 0}
[ -n "\$p" ] || p=\$HOME
if ! cd -- "\$p" 2>/dev/null; then
  if [ -d "\$p" ]; then exit 4; fi
  exit 3
fi
printf '%s\\000%s\\000%s\\000' '$_marker' "\$(pwd)" "\$HOME"
if [ "\$h" = 1 ]; then set -- ./* ./.[!.]* ./..?*; else set -- ./*; fi
n=0
for e in "\$@"; do
  [ -d "\$e" ] || continue
  n=\$((n+1))
  if [ \$n -gt $cap ]; then printf '\\000T\\000'; break; fi
  if [ -r "\$e" ] && [ -x "\$e" ]; then f=1; else f=0; fi
  printf '%s\\000%s\\000' "\${e#./}" "\$f"
done
exit 0
''';
}

/// Parses the script output. Throws [ListDirException] on a failed [exitCode].
DirListing parseListDir(
  String stdout, {
  required int? exitCode,
  String stderr = '',
  String requested = '',
}) {
  if (exitCode == 3) {
    throw ListDirException(ListDirFailure.notFound, requested, stderr);
  }
  if (exitCode == 4) {
    throw ListDirException(ListDirFailure.noPermission, requested, stderr);
  }
  final at = stdout.indexOf('$_marker\u0000');
  if (exitCode != 0 || at < 0) {
    throw ListDirException(
      ListDirFailure.other,
      requested,
      stderr.isNotEmpty ? stderr : stdout,
    );
  }
  final fields = stdout.substring(at + _marker.length + 1).split('\u0000');
  if (fields.isNotEmpty && fields.last.isEmpty) fields.removeLast();
  if (fields.length < 2) {
    throw ListDirException(ListDirFailure.other, requested, 'short output');
  }
  final entries = <DirEntry>[];
  var truncated = false;
  for (var i = 2; i + 1 < fields.length; i += 2) {
    final name = fields[i];
    final flag = fields[i + 1];
    if (name.isEmpty) {
      if (flag == 'T') truncated = true;
      continue;
    }
    entries.add(DirEntry(name, enterable: flag == '1'));
  }
  entries.sort((a, b) {
    final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return c != 0 ? c : a.name.compareTo(b.name);
  });
  return DirListing(
    path: fields[0],
    home: fields[1],
    entries: entries,
    truncated: truncated,
  );
}
