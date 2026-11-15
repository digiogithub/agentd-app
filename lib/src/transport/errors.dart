// Errors raised by the SSH transport.

/// The host presented a key whose fingerprint differs from the one trusted
/// for it. The connection is always aborted: the user must remove the saved
/// fingerprint explicitly before trusting a new key.
class HostKeyMismatch implements Exception {
  const HostKeyMismatch({required this.hostId, required this.expected, required this.actual, this.keyType});
  final String hostId;
  final String expected;
  final String actual;
  final String? keyType;

  @override
  String toString() => 'HostKeyMismatch: host $hostId presented $actual, expected $expected';
}

/// The host key was new and the user (the `onNewHostKey` callback) declined
/// it, or there was no callback to ask.
class HostKeyRejected implements Exception {
  const HostKeyRejected({required this.hostId, required this.fingerprint, this.keyType});
  final String hostId;
  final String fingerprint;
  final String? keyType;

  @override
  String toString() => 'HostKeyRejected: host $hostId key $fingerprint was not trusted';
}

/// No usable credentials for a host (missing key, bad passphrase...).
class SshCredentialsError implements Exception {
  const SshCredentialsError(this.message);
  final String message;

  @override
  String toString() => 'SshCredentialsError: $message';
}
