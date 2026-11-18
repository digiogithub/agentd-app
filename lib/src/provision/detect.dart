// Host detection: one POSIX sh script (no jq/python/bash needed on the host)
// printing `@@agentd-app <section>` marker lines, and its parser.

import 'dart:convert';

import '../core/contracts.dart';

/// Tools probed by [detectScript], with the arguments that print their
/// version (tmux has no --version; agentd prints it with `version`).
const detectTools = <String, String>{
  'agentd': 'version',
  'zellij': '--version',
  'tmux': '-V',
  'node': '--version',
  'npm': '--version',
  'claude': '--version',
  'codex': '--version',
  'pando': '--version',
  'opencode': '--version',
  'gemini': '--version',
  'grok': '--version',
};

const marker = '@@agentd-app ';

/// The detection script. Every probe has its stdin closed and a 5 s limit
/// (`timeout`/`gtimeout` when present, else a sleep-and-kill watchdog), so a
/// tool that waits for input or hangs cannot stall detection. The watchdog
/// writes the probe's output to a temp file (`mktemp`, else
/// `$HOME/.agentd-app-run5.$$`, removed afterwards) rather than a pipe: a
/// grandchild it does not kill (the `sleep` of a shell wrapper) would keep
/// the pipe open. Its `wait` discards stderr, where the shell reports the
/// killed job ("Terminated"). the user-level
/// binary directories (`~/.local/bin`, `~/bin`, `~/.bun/bin`, `~/.cargo/bin`, nvm, ...)
/// are searched as well: non-interactive login shells often do
/// not have them on PATH, and that is where the installers put binaries.
final String detectScript = () {
  final b = StringBuffer(r'''
PATH0=$PATH
PATH="$HOME/.local/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.npm-global/bin:$HOME/.volta/bin:$HOME/.local/share/pnpm:$HOME/go/bin:$HOME/.deno/bin:$HOME/.local/share/mise/shims:$HOME/.asdf/shims:$PATH:/usr/local/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"
for d in "$HOME"/.nvm/versions/node/*/bin "$HOME"/.local/share/fnm/node-versions/*/installation/bin; do [ -d "$d" ] && PATH="$PATH:$d"; done
export PATH
m() { printf '@@agentd-app %s\n' "$*"; }
if command -v timeout >/dev/null 2>&1; then TO=timeout
elif command -v gtimeout >/dev/null 2>&1; then TO=gtimeout
else TO=; fi
run5() {
  if [ -n "$TO" ]; then "$TO" 5 "$@"; return; fi
  o5=$(mktemp 2>/dev/null) || o5="$HOME/.agentd-app-run5.$$"
  "$@" >"$o5" 2>&1 & p5=$!
  ( sleep 5; kill "$p5" 2>/dev/null ) >/dev/null 2>&1 &
  w5=$!
  wait "$p5" 2>/dev/null; s5=$?
  kill "$w5" 2>/dev/null
  cat "$o5" 2>/dev/null; rm -f "$o5" 2>/dev/null
  return $s5
}
tool() {
  n=$1; shift
  m "tool $n"
  p=$(command -v "$n" 2>/dev/null) || p=
  case $p in /*) ;; *) return 0 ;; esac
  printf 'path=%s\n' "$p"
  v=$(run5 "$p" "$@" </dev/null 2>&1 | sed -n '/[^[:space:]]/{p;q;}')
  printf 'version=%s\n' "$v"
}
m os; uname -s 2>/dev/null
m arch; uname -m 2>/dev/null
m os-release; [ -r /etc/os-release ] && cat /etc/os-release
m macos
if command -v sw_vers >/dev/null 2>&1; then
  printf 'name=%s\nversion=%s\n' "$(sw_vers -productName 2>/dev/null)" "$(sw_vers -productVersion 2>/dev/null)"
fi
m uid; id -u
m home; printf '%s\n' "$HOME"
m path; printf '%s\n' "$PATH0"
m runtime-dir; printf '%s\n' "${XDG_RUNTIME_DIR:-}"
m systemd
if command -v systemctl >/dev/null 2>&1 && run5 systemctl --user show-environment </dev/null >/dev/null 2>&1; then echo yes; else echo no; fi
''');
  detectTools.forEach((name, args) => b.writeln('tool $name $args'));
  b.write(r'''
m socket
u=$(id -u)
for s in "${AGENTD_SOCKET:-}" "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/agentd/agentd.sock}" "/run/user/$u/agentd/agentd.sock" "/tmp/agentd-$u/agentd.sock"; do
  [ -n "$s" ] && [ -S "$s" ] && printf 'live=%s\n' "$s"
done
if [ -n "${AGENTD_SOCKET:-}" ]; then printf 'default=%s\n' "$AGENTD_SOCKET"
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then printf 'default=%s\n' "$XDG_RUNTIME_DIR/agentd/agentd.sock"
else printf 'default=/tmp/agentd-%s/agentd.sock\n' "$u"; fi
m end
''');
  return b.toString();
}();

/// Everything [detectScript] reports; [capabilities] is the contract view.
class DetectReport {
  DetectReport(this.sections);

  /// Section name → its lines (without the marker line).
  final Map<String, List<String>> sections;

  String _first(String s) => (sections[s] ?? const []).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();

  Map<String, String> _kv(String s) {
    final res = <String, String>{};
    for (final l in sections[s] ?? const <String>[]) {
      final i = l.indexOf('=');
      if (i > 0) res.putIfAbsent(l.substring(0, i).trim(), () => l.substring(i + 1).trim());
    }
    return res;
  }

  String get os => _first('os');
  String get arch => _first('arch');
  String? get uid => _nonEmpty(_first('uid'));
  String? get home => _nonEmpty(_first('home'));
  String? get runtimeDir => _nonEmpty(_first('runtime-dir'));
  bool get systemdUser => _first('systemd') == 'yes';

  /// The login PATH before the script added `~/.local/bin`.
  String? get loginPath => _nonEmpty(_first('path'));

  /// True when `~/.local/bin` is on the login PATH (binaries installed there
  /// are then found by `sh -lc`).
  bool get localBinOnPath {
    final h = home;
    final p = loginPath;
    if (h == null || p == null) return false;
    return p.split(':').contains('$h/.local/bin');
  }

  /// Complete section ("@@agentd-app end" seen): a truncated run is suspect.
  bool get complete => sections.containsKey('end');

  String? get distro {
    final osr = _kv('os-release').map((k, v) => MapEntry(k, _unquote(v)));
    final pretty = osr['PRETTY_NAME'];
    if (pretty != null && pretty.isNotEmpty) return pretty;
    final name = osr['NAME'];
    if (name != null && name.isNotEmpty) return [name, osr['VERSION_ID']].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    final mac = _kv('macos');
    final mn = mac['name'];
    if (mn != null && mn.isNotEmpty) return [mn, mac['version']].whereType<String>().where((s) => s.isNotEmpty).join(' ');
    return null;
  }

  Map<String, ToolInfo> get tools {
    final res = <String, ToolInfo>{};
    for (final name in detectTools.keys) {
      final kv = _kv('tool $name');
      final path = _nonEmpty(kv['path']);
      res[name] = ToolInfo(name, installed: path != null, path: path, version: path == null ? null : cleanVersion(kv['version']));
    }
    return res;
  }

  /// Live sockets found, most specific first.
  List<String> get liveSockets => [
        for (final l in sections['socket'] ?? const <String>[])
          if (l.startsWith('live=')) l.substring(5).trim(),
      ];

  String? get defaultSocket => _nonEmpty(_kv('socket')['default']);

  /// The daemon socket the app should open: a live one, else (agentd
  /// installed) where the daemon will create it, else null.
  String? get agentdSocket {
    final live = liveSockets;
    if (live.isNotEmpty) return live.first;
    if (tools['agentd']?.installed ?? false) return defaultSocket;
    return null;
  }

  HostCapabilities get capabilities => HostCapabilities(
        os: os,
        arch: arch,
        distro: distro,
        systemdUser: systemdUser,
        runtimeDir: runtimeDir,
        agentdSocket: agentdSocket,
        tools: tools,
      );
}

String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

String _unquote(String v) {
  if (v.length >= 2 && (v.startsWith('"') && v.endsWith('"') || v.startsWith("'") && v.endsWith("'"))) {
    return v.substring(1, v.length - 1);
  }
  return v;
}

final _semver = RegExp(r'v?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.+-]+)?)');

/// The version number in a `--version` line (`zellij 0.44.3` → `0.44.3`,
/// `v22.11.0` → `22.11.0`, `2.0.76 (Claude Code)` → `2.0.76`,
/// `tmux 3.4` → `3.4`, `tmux next-3.5` → `3.5`); the trimmed line when it
/// has no number; null when empty.
String? cleanVersion(String? line) {
  final l = line?.trim() ?? '';
  if (l.isEmpty) return null;
  final m = _semver.firstMatch(l);
  return m == null ? l : m.group(1);
}

/// Splits [detectScript] output into sections.
DetectReport parseDetect(String out) {
  final sections = <String, List<String>>{};
  List<String>? cur;
  for (final line in const LineSplitter().convert(out)) {
    final l = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    if (l.startsWith(marker)) {
      final name = l.substring(marker.length).trim();
      cur = sections.putIfAbsent(name, () => <String>[]);
    } else {
      cur?.add(l);
    }
  }
  return DetectReport(sections);
}
