// Errors of the agentd client: daemon-side refusals (AgentdError, carrying
// the daemon's stable error code) and local transport / protocol failures
// (AgentdTransportError).

/// Stable error classes sent by the daemon in `code` (agentd
/// `internal/proto`, Code*). An empty or unknown code means unclassified.
abstract final class AgentdErrorCode {
  static const invalid = 'invalid';
  static const notFound = 'not_found';
  static const starting = 'starting';
  static const exited = 'exited';
  static const exists = 'exists';
  static const forbidden = 'forbidden';
  static const conflict = 'conflict';
  static const busy = 'busy';
  static const notReady = 'not_ready';
  static const verifyFailed = 'verify_failed';
  static const timeout = 'timeout';
  static const internal = 'internal';
}

/// A daemon answer with `ok: false`. [message] is the daemon's text,
/// [code] its error class ("" = unclassified) and [data] the optional
/// structured context (for an act `conflict`: `{revision, view}`).
class AgentdError implements Exception {
  const AgentdError(this.message, {this.code = '', this.data, this.op});

  final String message;
  final String code;
  final Object? data;

  /// The op that failed, when known.
  final String? op;

  bool get isConflict => code == AgentdErrorCode.conflict;
  bool get isBusy => code == AgentdErrorCode.busy;
  bool get isNotReady => code == AgentdErrorCode.notReady;
  bool get isNotFound => code == AgentdErrorCode.notFound;
  bool get isForbidden => code == AgentdErrorCode.forbidden;

  /// Whether retrying the same request later may succeed.
  bool get isRetryable => code == AgentdErrorCode.starting || code == AgentdErrorCode.busy || code == AgentdErrorCode.timeout;

  @override
  String toString() => 'AgentdError(${op != null ? '$op: ' : ''}$message${code.isNotEmpty ? ' [$code]' : ''})';
}

/// A local failure talking to the daemon: the channel could not be opened
/// or closed early, a line or frame was malformed or too large, or the
/// daemon did not answer in time.
class AgentdTransportError implements Exception {
  const AgentdTransportError(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'AgentdTransportError($message${cause != null ? ': $cause' : ''})';
}
