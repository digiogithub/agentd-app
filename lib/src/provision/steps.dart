// Install steps (titles are UI copy, in Spanish): every step is one self-contained, idempotent POSIX sh
// script, shown to the user before it runs (ProvisionService.plan) and run
// as is (ProvisionService.install). Runtime facts (npm prefix permissions,
// existing config, a running daemon) are checked by the scripts themselves
// on the host, so the plan is exact whatever detection missed.
//
// Sources:
// - agentd: /www/MCP/agentd/install.sh and docs/release.md: the release
//   attaches `install.sh` and `SHA256SUMS` (which lists install.sh), so
//   `https://github.com/digiogithub/agentd/releases/latest/download/<file>`
//   always serves the latest; install.sh resolves the tag from the
//   `/releases/latest` redirect, picks `agentd_<v>_linux_<amd64|arm64>.tar.gz`
//   or `agentd_<v>_darwin_universal.zip`, verifies it against SHA256SUMS,
//   installs `~/.local/bin/agentd` and, on Linux, writes the systemd user
//   unit from the tarball unless one exists.
// - service: README.md "systemd (optional)", contrib/agentd.service
//   (`systemctl --user daemon-reload && systemctl --user enable --now agentd`,
//   `loginctl enable-linger`).
// - hc listener: AGENTS.md "Herdr compatibility": `[herdr] listen` is read at
//   daemon start; `hc server start --json` (`agentd hc server start`) asks a
//   running daemon to bind it and prints `agentd.listener.listening`.
// - MCP: `agentd mcp install --print` only prints snippets (cmd/agentd/main.go
//   mcpInstallCmd, "never writes config files"), so the app applies the
//   documented snippets itself: `claude mcp add --scope user agentd --
//   <agentd> mcp`, `[mcp_servers.agentd]` in ~/.codex/config.toml,
//   `[MCPServers.agentd]` in ~/.pando.toml.
// - CLIs: npm packages; Pando: /www/MCP/Pando/pando/README.md and
//   scripts/install.sh (`--no-desktop --cli-only`: no GTK packages or sudo).

import '../core/contracts.dart';
import '../mux/quote.dart';

const agentdRepo = 'digiogithub/agentd';
const agentdLatest = 'https://github.com/$agentdRepo/releases/latest/download';
const pandoInstaller = 'https://raw.githubusercontent.com/digiogithub/pando/main/scripts/install.sh';

/// npm packages of the npm-installed CLIs.
const npmPackages = <String, String>{
  'claude': '@anthropic-ai/claude-code',
  'codex': '@openai/codex',
  'opencode': 'opencode-ai',
  'gemini': '@google/gemini-cli',
};

/// CLIs [buildPlan] knows how to install.
const installableClis = ['claude', 'codex', 'pando', 'opencode', 'gemini'];

/// Harnesses whose MCP registration the mcp step writes.
const mcpHarnesses = ['claude', 'codex', 'pando'];

const _path = r'PATH="$HOME/.local/bin:$PATH"; export PATH';
const _cache = r'd="${XDG_CACHE_HOME:-$HOME/.cache}/agentd-app"';
const _needAgentd = r'a=$(command -v agentd) || { echo "agentd is not installed" >&2; exit 127; }';

String _download() => '''
set -e
$_path
$_cache
mkdir -p "\$d"
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 127; }
curl -fsSL -o "\$d/install.sh" $agentdLatest/install.sh
curl -fsSL -o "\$d/SHA256SUMS" $agentdLatest/SHA256SUMS
echo "downloaded install.sh and SHA256SUMS to \$d"''';

String _verify() => '''
set -e
$_cache
want=\$(awk '\$2 == "install.sh" || \$2 == "*install.sh" { print \$1 }' "\$d/SHA256SUMS")
[ -n "\$want" ] || { echo "install.sh is not listed in SHA256SUMS" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then got=\$(sha256sum "\$d/install.sh" | cut -d' ' -f1)
elif command -v shasum >/dev/null 2>&1; then got=\$(shasum -a 256 "\$d/install.sh" | cut -d' ' -f1)
else echo "needs sha256sum or shasum" >&2; exit 127; fi
[ "\$got" = "\$want" ] || { echo "checksum mismatch for install.sh (got \$got, want \$want)" >&2; exit 1; }
echo "install.sh sha256 \$got"''';

String _install() => '''
set -e
$_path
$_cache
sh "\$d/install.sh"
agentd version''';

const _sock = r'''sock=${AGENTD_SOCKET:-}
if [ -z "$sock" ]; then
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then sock=$XDG_RUNTIME_DIR/agentd/agentd.sock; else sock=/tmp/agentd-$(id -u)/agentd.sock; fi
fi''';

String _serviceSystemd() => '''
set -e
$_path
$_sock
systemctl --user daemon-reload
systemctl --user cat agentd >/dev/null 2>&1 || { echo "no systemd user unit agentd.service (see contrib/agentd.service)" >&2; exit 1; }
if ! systemctl --user is-active --quiet agentd && [ -S "\$sock" ]; then
  # A CLI-autostarted daemon owns the socket: starting the unit now would
  # fail (or, after a shutdown, end its sessions). Enable it for next time.
  systemctl --user enable agentd
  echo "agentd already runs outside systemd; the unit is enabled for the next login"
  exit 0
fi
systemctl --user enable --now agentd
loginctl enable-linger "\$(id -un)" 2>/dev/null || echo "note: lingering not enabled: agentd stops when your last login session ends"
systemctl --user is-active agentd''';

String _serviceAutostart() => '''
set -e
$_path
$_needAgentd
"\$a" ls >/dev/null
echo "agentd daemon running (started by the CLI; no systemd user manager on this host)"''';

String _hcListener() => '''
set -e
$_path
f="\${XDG_CONFIG_HOME:-\$HOME/.config}/agentd/config.toml"
mkdir -p "\$(dirname "\$f")"
hdr='^[[:space:]]*\\[herdr\\][[:space:]]*(#.*)?\$'
if [ -f "\$f" ] && grep -Eq "\$hdr" "\$f"; then
  cur=\$(awk '/^[ \t]*\\[/ { t = (\$0 ~ /^[ \t]*\\[herdr\\][ \t]*(#.*)?\$/) } t && /^[ \t]*listen[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]*(#.*)?\$/, ""); print; exit }' "\$f")
  if [ -n "\$cur" ]; then
    echo "kept [herdr] listen = \$cur in \$f"
  else
    awk '{ print } !done && /^[ \t]*\\[herdr\\][ \t]*(#.*)?\$/ { print "listen = true"; done = 1 }' "\$f" > "\$f.agentd-app.tmp"
    cat "\$f.agentd-app.tmp" > "\$f"; rm -f "\$f.agentd-app.tmp"
    echo "added listen = true to [herdr] in \$f"
  fi
else
  printf '\\n[herdr]\\nlisten = true\\n' >> "\$f"
  echo "appended [herdr] listen = true to \$f"
fi
command -v agentd >/dev/null 2>&1 || { echo "agentd is not installed yet: the listener starts with the daemon"; exit 0; }
st=\$(agentd hc server status --json 2>/dev/null) || { echo "agentd daemon not running: the listener starts with it"; exit 0; }
case \$st in *'"listening":true'*) echo "hc listener already listening"; exit 0 ;; esac
out=\$(agentd hc server start --json 2>/dev/null || true)
case \$out in *'"listening":true'*) echo "hc listener listening"; exit 0 ;; esac
n=\$(agentd ls --json 2>/dev/null | grep -c '"state": *"running"' || true)
if [ "\${n:-0}" -gt 0 ]; then
  echo "restart agentd to start the hc listener (\$n running sessions would end; not restarted)"
  exit 0
fi
if systemctl --user is-active --quiet agentd 2>/dev/null; then systemctl --user restart agentd
else agentd shutdown >/dev/null 2>&1 || true; fi
sleep 1
out=\$(agentd hc server start --json 2>&1 || true)
case \$out in *'"listening":true'*) echo "hc listener listening (daemon restarted; no session was running)" ;;
  *) echo "hc listener not listening: \$out" >&2; exit 1 ;; esac''';

String _mcpClaude() => '''
set -e
$_path
$_needAgentd
command -v claude >/dev/null 2>&1 || { echo "claude is not installed" >&2; exit 127; }
if claude mcp get agentd >/dev/null 2>&1; then echo "claude: agentd MCP server already registered"; exit 0; fi
claude mcp add --scope user agentd -- "\$a" mcp''';

String _mcpCodex() => '''
set -e
$_path
$_needAgentd
f="\${CODEX_HOME:-\$HOME/.codex}/config.toml"
if [ -f "\$f" ] && grep -Eq '^[[:space:]]*\\[mcp_servers\\.("agentd"|agentd)\\]' "\$f"; then echo "codex: agentd MCP server already in \$f"; exit 0; fi
mkdir -p "\$(dirname "\$f")"
printf '\\n[mcp_servers.agentd]\\ncommand = "%s"\\nargs = ["mcp"]\\n' "\$a" >> "\$f"
echo "codex: added [mcp_servers.agentd] to \$f"''';

String _mcpPando() => '''
set -e
$_path
$_needAgentd
x="\${XDG_CONFIG_HOME:-\$HOME/.config}/pando"
f=
for c in "\$HOME/.pando.toml" "\$x/.pando.toml"; do [ -f "\$c" ] && { f=\$c; break; }; done
if [ -z "\$f" ]; then
  for j in "\$HOME/.pando.json" "\$x/.pando.json"; do
    [ -f "\$j" ] && { echo "pando uses \$j: add mcpServers.agentd there (agentd mcp install --print --harness pando)" >&2; exit 1; }
  done
  f="\$HOME/.pando.toml"
fi
if grep -Eq '^[[:space:]]*\\[MCPServers\\.("agentd"|agentd)\\]' "\$f" 2>/dev/null; then echo "pando: agentd MCP server already in \$f"; exit 0; fi
printf "\\n[MCPServers.agentd]\\nType = 'stdio'\\nCommand = '%s'\\nArgs = ['mcp']\\n" "\$a" >> "\$f"
echo "pando: added [MCPServers.agentd] to \$f"''';

String _npmCli(String cli, String pkg) {
  final q = posixQuote(pkg);
  return '''
set -e
$_path
if command -v $cli >/dev/null 2>&1; then echo "$cli already installed: \$(command -v $cli)"; exit 0; fi
command -v npm >/dev/null 2>&1 || { echo "npm is not installed (install Node.js first)" >&2; exit 127; }
p=\$(npm config get prefix 2>/dev/null || true)
if [ -n "\$p" ] && [ -w "\$p" ] && { [ ! -e "\$p/lib/node_modules" ] || [ -w "\$p/lib/node_modules" ]; }; then
  npm install -g $q
else
  # The global prefix is not writable (system Node): install for this user.
  npm install -g --prefix "\$HOME/.local" $q
fi
command -v $cli''';
}

String _pandoCli() => '''
set -e
$_path
if command -v pando >/dev/null 2>&1; then echo "pando already installed: \$(command -v pando)"; exit 0; fi
command -v bash >/dev/null 2>&1 || { echo "the Pando installer needs bash" >&2; exit 127; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 127; }
$_cache
mkdir -p "\$d"
curl -fsSL -o "\$d/pando-install.sh" $pandoInstaller
bash "\$d/pando-install.sh" --no-desktop --cli-only
command -v pando''';

/// Builds the ordered install plan. Steps are skipped when detection says
/// their result is already there (agentd installed, CLI installed); the
/// remaining scripts also check on the host and do nothing twice.
List<PlannedStep> buildPlan(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) {
  final steps = <PlannedStep>[];
  final installAgentd = agentd && !caps.has('agentd');
  if (installAgentd) {
    steps
      ..add(PlannedStep(step: ProvisionStep.download, title: 'Descargar el instalador de agentd', command: _download(), group: 'agentd'))
      ..add(PlannedStep(step: ProvisionStep.verify, title: 'Comprobar install.sh con SHA256SUMS', command: _verify(), group: 'agentd'))
      ..add(PlannedStep(step: ProvisionStep.install, title: 'Instalar agentd en ~/.local/bin', command: _install(), group: 'agentd'));
  }
  // The listener setting goes in before the service starts, so a fresh
  // daemon reads it at its first start.
  if (hcListener) {
    steps.add(PlannedStep(step: ProvisionStep.hcListener, title: 'Activar el listener herdr-core ([herdr] listen = true)', command: _hcListener(), group: 'hc', needs: const {'agentd'}));
  }
  if (agentd) {
    steps.add(caps.systemdUser
        ? PlannedStep(step: ProvisionStep.service, title: 'Activar el servicio de usuario de agentd', command: _serviceSystemd(), group: 'service', needs: const {'agentd'})
        : PlannedStep(step: ProvisionStep.service, title: 'Arrancar el daemon de agentd', command: _serviceAutostart(), group: 'service', needs: const {'agentd'}));
  }
  for (final cli in installableClis.where(clis.contains)) {
    if (caps.has(cli)) continue;
    final pkg = npmPackages[cli];
    steps.add(PlannedStep(
      step: ProvisionStep.cli,
      title: pkg == null ? 'Instalar $cli (instalador oficial)' : 'Instalar $cli (npm $pkg)',
      command: pkg == null ? _pandoCli() : _npmCli(cli, pkg),
      group: 'cli:$cli',
      timeout: const Duration(minutes: 10),
    ));
  }
  if (mcp) {
    for (final h in mcpHarnesses) {
      if (!caps.has(h) && !clis.contains(h)) continue;
      final cmd = switch (h) { 'claude' => _mcpClaude(), 'codex' => _mcpCodex(), _ => _mcpPando() };
      steps.add(PlannedStep(step: ProvisionStep.mcp, title: 'Registrar el MCP de agentd en $h', command: cmd, group: 'mcp:$h', needs: {'agentd', 'cli:$h'}));
    }
  }
  return steps;
}
