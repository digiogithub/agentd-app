import 'dart:typed_data';

import 'package:agentd_app/src/transport/errors.dart';
import 'package:agentd_app/src/transport/key_store.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/ed25519.dart' as ed;

import 'fixtures.dart';

void main() {
  test('generate -> PEM -> parse back gives the same public key and signs', () {
    final pair = generateEd25519();
    final pem = pair.toPem();
    expect(pem, contains('BEGIN OPENSSH PRIVATE KEY'));
    final back = SSHKeyPair.fromPem(pem).single;
    expect(back.toPublicKey().encode(), pair.toPublicKey().encode());
    final data = Uint8List.fromList('challenge'.codeUnits);
    final sig = back.sign(data);
    // Verify the signature with the raw 32-byte public key (last field of the blob).
    final blob = back.toPublicKey().encode();
    final raw = blob.sublist(blob.length - 32);
    final sigBlob = sig.encode();
    final rawSig = sigBlob.sublist(sigBlob.length - 64);
    expect(ed.VerifyKey(raw).verify(signature: ed.Signature(rawSig), message: data), isTrue);
  });

  test('ensureGeneratedKey generates once and returns the OpenSSH line', () async {
    final ks = MemoryKeyStore();
    final line = await ks.ensureGeneratedKey();
    expect(line, matches(RegExp(r'^ssh-ed25519 AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/=]+ agentd-app$')));
    expect(await ks.ensureGeneratedKey(), line);
    expect(await ks.publicKey(defaultKeyId), line);
    final ids = await ks.identities(defaultKeyId);
    expect(ids.single.type, 'ssh-ed25519');
  });

  test('two generated keys differ', () async {
    expect(await MemoryKeyStore().ensureGeneratedKey(), isNot(await MemoryKeyStore().ensureGeneratedKey()));
  });

  test('import unencrypted ed25519', () async {
    final ks = MemoryKeyStore();
    final line = await ks.importKey('k1', plainPem);
    expect(line, '$plainPub agentd-app');
    expect((await ks.identities('k1')).single.toPublicKey().encode(), isNotEmpty);
  });

  test('import encrypted key needs the right passphrase and stores it decrypted', () async {
    final ks = MemoryKeyStore();
    expect(() => ks.importKey('k', encPem), throwsA(isA<SshCredentialsError>()));
    expect(() => ks.importKey('k', encPem, passphrase: 'wrong'), throwsA(isA<SshCredentialsError>()));
    expect(await ks.has('k'), isFalse);
    final line = await ks.importKey('k', encPem, passphrase: encPassphrase);
    expect(line, '$encPub agentd-app');
    // Stored decrypted: usable without the passphrase.
    expect((await ks.identities('k')).single.type, 'ssh-ed25519');
  });

  test('import PKCS#1 RSA', () async {
    final ks = MemoryKeyStore();
    final line = await ks.importKey('r', rsaPem);
    expect(line, '$rsaPub agentd-app');
    expect((await ks.identities('r')).single.toPublicKey().encode(), isNotEmpty);
  });

  test('garbage and missing keys are SshCredentialsError', () async {
    final ks = MemoryKeyStore();
    expect(() => ks.importKey('x', 'not a key'), throwsA(isA<SshCredentialsError>()));
    expect(() => ks.identities('missing'), throwsA(isA<SshCredentialsError>()));
    expect(await ks.publicKey('missing'), isNull);
  });

  test('delete and passwords', () async {
    final ks = MemoryKeyStore();
    await ks.ensureGeneratedKey();
    await ks.delete(defaultKeyId);
    expect(await ks.has(defaultKeyId), isFalse);
    await ks.savePassword('h', 'pw');
    expect(await ks.password('h'), 'pw');
    await ks.deletePassword('h');
    expect(await ks.password('h'), isNull);
  });
}
