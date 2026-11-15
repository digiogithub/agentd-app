// OpenSSH-style key fingerprints and public key lines.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/digests.dart';

/// OpenSSH `SHA256:<base64 without padding>` fingerprint of a public key in
/// SSH wire encoding (the host key blob, or [SSHHostKey.encode]).
String sshFingerprint(Uint8List keyBlob) {
  final digest = Hash.sha256(keyBlob);
  return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
}

/// Canonical form of a fingerprint for comparison: `SHA256:` prefix added
/// when missing, base64 padding and surrounding whitespace removed.
String normalizeFingerprint(String fingerprint) {
  var f = fingerprint.trim();
  if (!f.startsWith('SHA256:')) f = 'SHA256:$f';
  while (f.endsWith('=')) {
    f = f.substring(0, f.length - 1);
  }
  return f;
}

/// Whether two fingerprints name the same key (see [normalizeFingerprint]).
bool sameFingerprint(String a, String b) => normalizeFingerprint(a) == normalizeFingerprint(b);

/// OpenSSH `authorized_keys` line for [key]: `<type> <base64 blob> <comment>`.
String publicKeyLine(SSHHostKey key, {String comment = 'agentd-app'}) {
  final blob = key.encode();
  final line = '${keyBlobType(blob)} ${base64.encode(blob)}';
  return comment.isEmpty ? line : '$line $comment';
}

/// Algorithm name at the start of an SSH wire-encoded key blob
/// (`uint32 length` + name), e.g. `ssh-ed25519`.
String keyBlobType(Uint8List blob) {
  if (blob.length < 4) throw const FormatException('key blob too short');
  final len = ByteData.sublistView(blob, 0, 4).getUint32(0);
  if (len > blob.length - 4) throw const FormatException('bad key blob');
  return latin1.decode(blob.sublist(4, 4 + len));
}
