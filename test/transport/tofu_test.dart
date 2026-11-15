import 'dart:convert';
import 'dart:typed_data';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/transport/connector.dart';
import 'package:agentd_app/src/transport/errors.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

const host = HostConfig(id: 'h1', name: 'box', host: 'box.local', user: 'me');

void main() {
  test('known host with the same key is accepted without asking', () async {
    var asked = false;
    final v = HostKeyVerifier(host: host, expected: plainFingerprint, onNewHostKey: (_, _, _) => asked = true);
    expect(await v.verify('ssh-ed25519', plainFingerprint), isTrue);
    expect(asked, isFalse);
    expect(v.accepted, isTrue);
    expect(v.isNew, isFalse);
    expect(v.failure(), isNull);
  });

  test('known host, padding/prefix differences still match', () async {
    final v = HostKeyVerifier(host: host, expected: '${plainFingerprint.substring(7)}=');
    expect(await v.verify('ssh-ed25519', plainFingerprint), isTrue);
  });

  test('mismatch is refused and reported as HostKeyMismatch, never asked', () async {
    var asked = false;
    final v = HostKeyVerifier(host: host, expected: 'SHA256:AAAA', onNewHostKey: (_, _, _) => asked = true);
    expect(await v.verify('ssh-ed25519', plainFingerprint), isFalse);
    expect(asked, isFalse);
    final f = v.failure();
    expect(f, isA<HostKeyMismatch>());
    f as HostKeyMismatch;
    expect(f.expected, 'SHA256:AAAA');
    expect(f.actual, plainFingerprint);
    expect(f.hostId, 'h1');
  });

  test('unknown host asks the callback with the fingerprint', () async {
    String? seen;
    final v = HostKeyVerifier(host: host, onNewHostKey: (h, type, fp) async {
      seen = '${h.id} $type $fp';
      return true;
    });
    // dartssh2 hands the fingerprint as UTF-8 bytes of the SHA256: string.
    expect(await v.verifyBytes('ssh-ed25519', Uint8List.fromList(utf8.encode(plainFingerprint))), isTrue);
    expect(seen, 'h1 ssh-ed25519 $plainFingerprint');
    expect(v.isNew, isTrue);
    expect(v.presented, plainFingerprint);
  });

  test('unknown host declined, or no callback, is HostKeyRejected', () async {
    final v1 = HostKeyVerifier(host: host, onNewHostKey: (_, _, _) => false);
    expect(await v1.verify('ssh-ed25519', plainFingerprint), isFalse);
    expect(v1.failure(), isA<HostKeyRejected>());
    final v2 = HostKeyVerifier(host: host);
    expect(await v2.verify('ssh-ed25519', plainFingerprint), isFalse);
    expect(v2.failure(), isA<HostKeyRejected>());
  });
}
