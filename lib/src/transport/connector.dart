// Opens authenticated SSH connections with trust-on-first-use host keys.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../core/contracts.dart';
import 'errors.dart';
import 'fingerprint.dart';
import 'host_key_store.dart';
import 'key_store.dart';
import 'ssh_shell.dart';

/// Asks the user whether to trust a host key seen for the first time.
/// [fingerprint] is `SHA256:...`, [keyType] e.g. `ssh-ed25519`.
typedef NewHostKeyCallback = FutureOr<bool> Function(HostConfig host, String keyType, String fingerprint);

/// Opens the TCP socket. Replaceable in tests.
typedef SocketFactory = Future<SSHSocket> Function(String host, int port, Duration timeout);

Future<SSHSocket> _defaultSocket(String host, int port, Duration timeout) => SSHSocket.connect(host, port, timeout: timeout);

/// Trust-on-first-use decision for one connect attempt.
///
/// [expected] is the trusted fingerprint (null = unknown host). A known host
/// must present exactly that key; an unknown one is accepted only if
/// [onNewHostKey] says so. The outcome is kept so the connector can turn the
/// generic dartssh2 host key error into [HostKeyMismatch] / [HostKeyRejected].
class HostKeyVerifier {
  HostKeyVerifier({required this.host, this.expected, this.onNewHostKey});

  final HostConfig host;
  final String? expected;
  final NewHostKeyCallback? onNewHostKey;

  String? presented;
  String? keyType;
  bool accepted = false;
  bool isNew = false;
  bool mismatch = false;
  bool rejected = false;

  /// dartssh2 `onVerifyHostKey` handler: [fingerprint] is the UTF-8 bytes of
  /// the OpenSSH `SHA256:...` string.
  Future<bool> verifyBytes(String type, Uint8List fingerprint) => verify(type, utf8.decode(fingerprint, allowMalformed: true));

  Future<bool> verify(String type, String fingerprint) async {
    keyType = type;
    presented = normalizeFingerprint(fingerprint);
    final want = expected;
    if (want != null) {
      if (sameFingerprint(want, fingerprint)) {
        accepted = true;
        return true;
      }
      mismatch = true;
      return false;
    }
    final ask = onNewHostKey;
    final ok = ask != null && await ask(host, type, presented!);
    if (ok) {
      accepted = true;
      isNew = true;
    } else {
      rejected = true;
    }
    return ok;
  }

  /// The error to raise for a failed connect, when it is a host key matter.
  Exception? failure() {
    if (mismatch) {
      return HostKeyMismatch(hostId: host.id, expected: normalizeFingerprint(expected!), actual: presented ?? '', keyType: keyType);
    }
    if (rejected) return HostKeyRejected(hostId: host.id, fingerprint: presented ?? '', keyType: keyType);
    return null;
  }
}

/// Connects to [HostConfig]s.
class SshConnector {
  SshConnector({this.onNewHostKey, this.keepAlive = const Duration(seconds: 15), SocketFactory? socketFactory})
      : _socket = socketFactory ?? _defaultSocket;

  /// Asked for unknown hosts. Without it unknown hosts are refused.
  final NewHostKeyCallback? onNewHostKey;

  /// SSH keepalive interval (global `keepalive@openssh.com` requests).
  final Duration keepAlive;

  final SocketFactory _socket;

  /// Connects and authenticates.
  ///
  /// Credentials: [AuthKind.password] uses [password] (or the one saved in
  /// [keyStore] under the host's keyId); key auth uses the key
  /// `config.keyId ?? defaultKeyId` from [keyStore] (required then).
  ///
  /// Host key: the trusted fingerprint is `config.hostKeyFingerprint`, else
  /// the one in [hostKeyStore]. A different key throws [HostKeyMismatch]; an
  /// unknown host goes through [onNewHostKey] ([HostKeyRejected] if refused).
  /// A newly accepted key is saved in [hostKeyStore] and reported by
  /// [SshRemoteShell.newHostKey] / [SshRemoteShell.hostKeyFingerprint], so
  /// the caller can store it in the config.
  Future<SshRemoteShell> connect(
    HostConfig config, {
    KeyStore? keyStore,
    HostKeyStore? hostKeyStore,
    String? password,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final expected = config.hostKeyFingerprint ?? await hostKeyStore?.get(config.id);
    final verifier = HostKeyVerifier(host: config, expected: expected, onNewHostKey: onNewHostKey);

    List<SSHIdentity>? identities;
    String? pass;
    if (config.auth == AuthKind.password) {
      pass = password ?? (config.keyId == null ? null : await keyStore?.password(config.keyId!));
      if (pass == null) throw const SshCredentialsError('no password for this host');
    } else {
      if (keyStore == null) throw const SshCredentialsError('a key store is required for key authentication');
      identities = await keyStore.identities(config.keyId ?? defaultKeyId);
    }

    final socket = await _socket(config.host, config.port, timeout);
    final client = SSHClient(
      socket,
      username: config.user,
      identities: identities,
      onPasswordRequest: pass == null ? null : () => pass,
      onUserInfoRequest: pass == null ? null : (req) => [for (final _ in req.prompts) pass!],
      onVerifyHostKey: verifier.verifyBytes,
      keepAliveInterval: keepAlive,
      handshakeTimeout: timeout,
      authTimeout: timeout,
    );

    try {
      await client.authenticated.timeout(timeout);
    } catch (e) {
      client.close();
      final hk = verifier.failure();
      if (hk != null) throw hk;
      if (e is TimeoutException) throw TimeoutException('SSH connect to ${config.host}:${config.port} timed out', timeout);
      rethrow;
    }

    // Defensive: dartssh2 aborts on a refused key, but never hand out a
    // connection whose host key was not accepted.
    if (!verifier.accepted) {
      client.close();
      throw verifier.failure() ?? HostKeyRejected(hostId: config.id, fingerprint: verifier.presented ?? '');
    }

    if (verifier.isNew && hostKeyStore != null) {
      await hostKeyStore.put(config.id, verifier.presented!);
    }
    return SshRemoteShell(client, hostId: config.id, hostKeyFingerprint: verifier.presented, newHostKey: verifier.isNew);
  }
}
