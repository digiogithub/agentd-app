import '../core/contracts.dart';

/// A terminal multiplexer on one host (zellij, tmux), driven over a
/// [RemoteShell]. The app shows its sessions in the inbox (screen only, no
/// chat view) and attaches to them in a PTY.
abstract class MuxAdapter {
  SessionSource get source;

  /// Sessions on the host; empty when the multiplexer has no server running.
  /// Throws [MuxException] when the multiplexer is missing or fails.
  Future<List<AgentSession>> list({bool withPanes = true});

  /// Attaches to [name] in a remote PTY.
  Future<PtySession> attach(String name, {int cols = 80, int rows = 24});

  /// Runs [command] (argv) in [cwd] inside session [session], creating the
  /// session when it does not exist.
  Future<AgentSession> launch({required String session, required String cwd, required List<String> command, String? harness});

  /// Ends session [name].
  Future<void> kill(String name);
}

class MuxException implements Exception {
  MuxException(this.message, {this.result});
  final String message;
  final ExecResult? result;

  @override
  String toString() => 'MuxException: $message';
}

/// Removes ANSI escape sequences (CSI, OSC) from [s].
String stripAnsi(String s) => s
    .replaceAll(RegExp(r'\x1b\[[0-9;?]*[ -/]*[@-~]'), '')
    .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)'), '');

/// Throws [MuxException] when [r] says [tool] is not installed.
void checkInstalled(String tool, ExecResult r) {
  final err = r.stderr.toLowerCase();
  if (r.exitCode == 127 || err.contains('command not found') || err.contains('not found: $tool') || err.contains('$tool: not found')) {
    throw MuxException('$tool is not installed', result: r);
  }
}
