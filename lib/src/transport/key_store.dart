// Client key storage: the app's generated ed25519 key and imported keys.
//
// Private keys are kept as unencrypted OpenSSH PEM in a secret store
// (flutter_secure_storage on devices, memory in tests). An imported key that
// was passphrase-protected is decrypted once at import time and stored
// decrypted: the secure store is the protection, so the passphrase is never
// kept. Nothing here logs key material.

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

import 'errors.dart';
import 'fingerprint.dart';

/// Key id used for the app's own generated key when a [HostConfig] has no
/// `keyId`.
const String defaultKeyId = 'app-ed25519';

/// Comment written at the end of the app's public key line.
const String defaultKeyComment = 'agentd-app';

/// Stores private keys by id and turns them into dartssh2 identities.
///
/// Subclasses only provide the raw secret storage ([readSecret],
/// [writeSecret], [deleteSecret]); the key logic is shared.
abstract class KeyStore {
  /// Raw secret for [name], or null.
  Future<String?> readSecret(String name);
  Future<void> writeSecret(String name, String value);
  Future<void> deleteSecret(String name);

  static String _slot(String keyId) => 'agentd.ssh.key.$keyId';

  /// Generates the ed25519 key [keyId] once (later calls reuse it) and
  /// returns its OpenSSH public key line (`ssh-ed25519 AAAA... agentd-app`).
  Future<String> ensureGeneratedKey({String keyId = defaultKeyId, String comment = defaultKeyComment}) async {
    final existing = await readSecret(_slot(keyId));
    if (existing != null) {
      return publicKeyLine(_parse(existing).first.toPublicKey(), comment: comment);
    }
    final pair = generateEd25519(comment: comment);
    await writeSecret(_slot(keyId), pair.toPem());
    return publicKeyLine(pair.toPublicKey(), comment: comment);
  }

  /// Imports an OpenSSH / PKCS#1 / SEC1 private key PEM as [keyId]
  /// (replacing any key with that id) and returns its public key line.
  /// [passphrase] is required for encrypted keys and ignored otherwise.
  /// Throws [SshCredentialsError] when the key cannot be read.
  Future<String> importKey(String keyId, String pem, {String? passphrase, String comment = defaultKeyComment}) async {
    final pairs = parsePrivateKey(pem, passphrase: passphrase);
    // Store only the first key, re-encoded unencrypted.
    final pair = pairs.first;
    await writeSecret(_slot(keyId), pair.toPem());
    return publicKeyLine(pair.toPublicKey(), comment: comment);
  }

  /// OpenSSH public key line of [keyId], or null when there is no such key.
  Future<String?> publicKey(String keyId, {String comment = defaultKeyComment}) async {
    final pem = await readSecret(_slot(keyId));
    if (pem == null) return null;
    return publicKeyLine(_parse(pem).first.toPublicKey(), comment: comment);
  }

  /// dartssh2 identities for [keyId]. Throws [SshCredentialsError] when the
  /// key is missing.
  Future<List<SSHKeyPair>> identities(String keyId) async {
    final pem = await readSecret(_slot(keyId));
    if (pem == null) throw SshCredentialsError('no private key stored for "$keyId"');
    return _parse(pem);
  }

  Future<bool> has(String keyId) async => await readSecret(_slot(keyId)) != null;

  Future<void> delete(String keyId) => deleteSecret(_slot(keyId));

  static String _passwordSlot(String keyId) => 'agentd.ssh.password.$keyId';

  /// Saved password for hosts with `AuthKind.password` (stored under the
  /// host's keyId), or null.
  Future<String?> password(String keyId) => readSecret(_passwordSlot(keyId));

  Future<void> savePassword(String keyId, String password) => writeSecret(_passwordSlot(keyId), password);

  Future<void> deletePassword(String keyId) => deleteSecret(_passwordSlot(keyId));

  List<SSHKeyPair> _parse(String pem) => parsePrivateKey(pem);
}

/// Generates a fresh ed25519 key pair in OpenSSH form.
OpenSSHEd25519KeyPair generateEd25519({String comment = defaultKeyComment}) {
  final signing = ed25519.SigningKey.generate();
  // OpenSSH keeps the 64-byte secret (seed + public key), as pinenacl does.
  return OpenSSHEd25519KeyPair(
    signing.verifyKey.asTypedList,
    signing.asTypedList,
    comment,
  );
}

/// Parses a private key PEM. Throws [SshCredentialsError] on any failure
/// (unsupported format, missing or wrong passphrase); the message never
/// contains key material.
List<SSHKeyPair> parsePrivateKey(String pem, {String? passphrase}) {
  try {
    final encrypted = SSHKeyPair.isEncryptedPem(pem);
    if (encrypted && (passphrase == null || passphrase.isEmpty)) {
      throw const SshCredentialsError('the private key is encrypted: a passphrase is required');
    }
    final pairs = SSHKeyPair.fromPem(pem, encrypted ? passphrase : null);
    if (pairs.isEmpty) throw const SshCredentialsError('no key found in the PEM');
    return pairs;
  } on SshCredentialsError {
    rethrow;
  } on SSHKeyDecryptError {
    throw const SshCredentialsError('wrong passphrase or corrupt private key');
  } catch (e) {
    throw SshCredentialsError('cannot read the private key (${e.runtimeType})');
  }
}

/// [KeyStore] in memory, for tests and demos.
class MemoryKeyStore extends KeyStore {
  final _secrets = <String, String>{};

  @override
  Future<String?> readSecret(String name) async => _secrets[name];

  @override
  Future<void> writeSecret(String name, String value) async => _secrets[name] = value;

  @override
  Future<void> deleteSecret(String name) async => _secrets.remove(name);
}

/// [KeyStore] in the platform secure storage (iOS Keychain, Android
/// Keystore).
class SecureKeyStore extends KeyStore {
  SecureKeyStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readSecret(String name) => _storage.read(key: name);

  @override
  Future<void> writeSecret(String name, String value) => _storage.write(key: name, value: value);

  @override
  Future<void> deleteSecret(String name) => _storage.delete(key: name);
}
