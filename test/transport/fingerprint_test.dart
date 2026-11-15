import 'dart:convert';
import 'dart:typed_data';

import 'package:agentd_app/src/transport/fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  test('sshFingerprint matches ssh-keygen -l', () {
    final blob = base64.decode(plainPub.split(' ')[1]);
    expect(sshFingerprint(Uint8List.fromList(blob)), plainFingerprint);
  });

  test('fingerprint has no base64 padding', () {
    final fp = sshFingerprint(Uint8List.fromList([1, 2, 3]));
    expect(fp, startsWith('SHA256:'));
    expect(fp.endsWith('='), isFalse);
    expect(fp.length, 'SHA256:'.length + 43);
  });

  test('normalize and compare', () {
    final bare = plainFingerprint.substring('SHA256:'.length);
    expect(normalizeFingerprint(' $bare= '), plainFingerprint);
    expect(sameFingerprint(plainFingerprint, '$bare='), isTrue);
    expect(sameFingerprint(plainFingerprint, 'SHA256:other'), isFalse);
  });

  test('keyBlobType', () {
    final blob = base64.decode(plainPub.split(' ')[1]);
    expect(keyBlobType(Uint8List.fromList(blob)), 'ssh-ed25519');
    expect(() => keyBlobType(Uint8List(2)), throwsFormatException);
  });
}
