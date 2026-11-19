// Noise handshake and transport for the relay tunnel (agentd
// docs/plans/agentd/relay_plan.md, "Tunnel"): Noise_IK_25519_ChaChaPoly_SHA256
// for paired devices and Noise_IKpsk2_25519_ChaChaPoly_SHA256 for invites
// (psk = the 32-byte invite code). Pure Dart over package `cryptography`
// (its synchronous Dart implementations), checked byte for byte against the
// Go vectors (test/relay/noise_vectors_test.dart).
//
// Nothing here logs key material or plaintexts.

import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Largest Noise message (handshake or transport).
const noiseMaxMsg = 65535;

/// Poly1305 tag length.
const noiseTagLen = 16;

const _hashLen = 32;
const _blockLen = 64;
const _sha256 = DartSha256();
const _x25519 = DartX25519();
const _aead = DartChacha20.poly1305Aead();

/// Raised when a Noise message cannot be decrypted / authenticated, or the
/// handshake is used out of order.
class NoiseError implements Exception {
  const NoiseError(this.message);
  final String message;

  @override
  String toString() => 'NoiseError: $message';
}

Uint8List _hash(List<int> data) => Uint8List.fromList(_sha256.hashSync(data).bytes);

Uint8List _hmac(List<int> key, List<int> data) {
  var k = key;
  if (k.length > _blockLen) k = _hash(k);
  final ipad = Uint8List(_blockLen + data.length);
  final opad = Uint8List(_blockLen + _hashLen);
  for (var i = 0; i < _blockLen; i++) {
    final b = i < k.length ? k[i] : 0;
    ipad[i] = b ^ 0x36;
    opad[i] = b ^ 0x5c;
  }
  ipad.setRange(_blockLen, ipad.length, data);
  opad.setRange(_blockLen, opad.length, _hash(ipad));
  return _hash(opad);
}

/// Noise HKDF with HMAC-SHA256: two or three 32-byte outputs.
List<Uint8List> _hkdf(List<int> ck, List<int> ikm, int n) {
  final temp = _hmac(ck, ikm);
  final o1 = _hmac(temp, const [1]);
  final o2 = _hmac(temp, [...o1, 2]);
  if (n == 2) return [o1, o2];
  final o3 = _hmac(temp, [...o2, 3]);
  return [o1, o2, o3];
}

final Uint8List _basepoint = Uint8List(32)..[0] = 9;

/// X25519(priv, pub). Throws [NoiseError] on an all-zero result (a
/// low-order peer point), like Go's curve25519.X25519.
Uint8List x25519(List<int> priv, List<int> pub) {
  final kp = SimpleKeyPairData(
    priv,
    publicKey: SimplePublicKey(_basepoint, type: KeyPairType.x25519),
    type: KeyPairType.x25519,
  );
  final out = Uint8List.fromList(
    (_x25519.sharedSecretSync(
      keyPairData: kp,
      remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519),
    ) as SecretKeyData).bytes,
  );
  if (out.every((b) => b == 0)) throw const NoiseError('bad public key');
  return out;
}

/// An X25519 key pair (raw 32-byte halves).
class DhKey {
  DhKey(this.private, this.public);

  /// Rebuilds the pair from its private half.
  factory DhKey.fromPrivate(List<int> priv) {
    if (priv.length != 32) throw ArgumentError('x25519 private key must be 32 bytes');
    final p = Uint8List.fromList(priv);
    return DhKey(p, x25519(p, _basepoint));
  }

  /// A fresh random key.
  factory DhKey.generate() {
    final r = Random.secure();
    return DhKey.fromPrivate(Uint8List.fromList(List<int>.generate(32, (_) => r.nextInt(256))));
  }

  final Uint8List private;
  final Uint8List public;
}

/// A Noise CipherState: ChaCha20-Poly1305 with a 64-bit counter nonce
/// (4 zero bytes + counter little endian).
class CipherState {
  CipherState([Uint8List? key]) : _key = key;

  Uint8List? _key;
  int _n = 0;

  bool get hasKey => _key != null;

  void initializeKey(Uint8List key) {
    _key = key;
    _n = 0;
  }

  Uint8List _nonce() {
    final b = Uint8List(12);
    var n = _n;
    for (var i = 4; i < 12; i++) {
      b[i] = n & 0xff;
      n >>= 8;
    }
    return b;
  }

  /// Encrypts [plain] with [ad] (passes it through without a key).
  Uint8List encrypt(List<int> plain, [List<int> ad = const []]) {
    final k = _key;
    if (k == null) return Uint8List.fromList(plain);
    if (_n == -1 >>> 1) throw const NoiseError('nonce exhausted');
    final box = _aead.encryptSync(plain, secretKey: SecretKeyData(k), nonce: _nonce(), aad: ad);
    _n++;
    final out = Uint8List(box.cipherText.length + noiseTagLen);
    out.setAll(0, box.cipherText);
    out.setAll(box.cipherText.length, box.mac.bytes);
    return out;
  }

  /// Decrypts and authenticates [ct]. Throws [NoiseError]; the nonce only
  /// advances on success.
  Uint8List decrypt(List<int> ct, [List<int> ad = const []]) {
    final k = _key;
    if (k == null) return Uint8List.fromList(ct);
    if (ct.length < noiseTagLen) throw const NoiseError('message too short');
    final split = ct.length - noiseTagLen;
    try {
      final box = SecretBox(ct.sublist(0, split), nonce: _nonce(), mac: Mac(ct.sublist(split)));
      final out = Uint8List.fromList(_aead.decryptSync(box, secretKey: SecretKeyData(k), aad: ad));
      _n++;
      return out;
    } on SecretBoxAuthenticationError {
      throw const NoiseError('authentication failed');
    }
  }
}

class _SymmetricState {
  _SymmetricState(String protocol) {
    final name = Uint8List.fromList(protocol.codeUnits);
    if (name.length <= _hashLen) {
      h = Uint8List(_hashLen)..setAll(0, name);
    } else {
      h = _hash(name);
    }
    ck = Uint8List.fromList(h);
  }

  late Uint8List h;
  late Uint8List ck;
  final CipherState cs = CipherState();

  void mixHash(List<int> data) => h = _hash([...h, ...data]);

  void mixKey(List<int> ikm) {
    final o = _hkdf(ck, ikm, 2);
    ck = o[0];
    cs.initializeKey(o[1]);
  }

  void mixKeyAndHash(List<int> ikm) {
    final o = _hkdf(ck, ikm, 3);
    ck = o[0];
    mixHash(o[1]);
    cs.initializeKey(o[2]);
  }

  Uint8List encryptAndHash(List<int> plain) {
    final ct = cs.encrypt(plain, h);
    mixHash(ct);
    return ct;
  }

  Uint8List decryptAndHash(List<int> ct) {
    final plain = cs.decrypt(ct, h);
    mixHash(ct);
    return plain;
  }

  (CipherState, CipherState) split() {
    final o = _hkdf(ck, const [], 2);
    return (CipherState(o[0]), CipherState(o[1]));
  }
}

/// Transport cipher states after a handshake: [send] encrypts what this side
/// writes, [recv] decrypts what it reads.
class NoiseTransport {
  NoiseTransport(this.send, this.recv);
  final CipherState send;
  final CipherState recv;
}

/// The IK / IKpsk2 handshake, both roles:
///
///     <- s
///     ...
///     -> e, es, s, ss
///     <- e, ee, se[, psk]
///
/// With a psk (placement 2) every `e` token also mixes the ephemeral public
/// key into the chaining key. The initiator knows the responder's static key
/// ([remoteStatic]) up front; the responder learns the initiator's from
/// message 1 ([remoteStatic] afterwards).
class IkHandshake {
  IkHandshake._({required this.initiator, required DhKey s, Uint8List? rs, required List<int> prologue, Uint8List? psk, this._e})
    : _s = s,
      _rs = rs,
      _psk = psk,
      _ss = _SymmetricState(psk == null ? protocolIK : protocolIKpsk2) {
    if (psk != null && psk.length != 32) throw ArgumentError('psk must be 32 bytes');
    _ss.mixHash(prologue);
    _ss.mixHash(initiator ? rs! : s.public);
  }

  /// Initiator (the client). [ephemeral] is for test vectors only.
  factory IkHandshake.initiator({required DhKey static, required List<int> remoteStatic, required List<int> prologue, List<int>? psk, DhKey? ephemeral}) {
    if (remoteStatic.length != 32) throw ArgumentError('remote static key must be 32 bytes');
    return IkHandshake._(
      initiator: true,
      s: static,
      rs: Uint8List.fromList(remoteStatic),
      prologue: prologue,
      psk: psk == null ? null : Uint8List.fromList(psk),
      e: ephemeral,
    );
  }

  /// Responder (the host; used by tests). [ephemeral] is for test vectors.
  factory IkHandshake.responder({required DhKey static, required List<int> prologue, List<int>? psk, DhKey? ephemeral}) =>
      IkHandshake._(initiator: false, s: static, prologue: prologue, psk: psk == null ? null : Uint8List.fromList(psk), e: ephemeral);

  static const protocolIK = 'Noise_IK_25519_ChaChaPoly_SHA256';
  static const protocolIKpsk2 = 'Noise_IKpsk2_25519_ChaChaPoly_SHA256';

  final bool initiator;
  final DhKey _s;
  Uint8List? _rs;
  Uint8List? _psk;
  DhKey? _e;
  Uint8List? _re;
  final _SymmetricState _ss;
  int _step = 0;

  /// Replaces the psk of a psk handshake before message 2 (the responder
  /// reads message 1 with a placeholder: psk2 does not use its value there).
  void setPsk(List<int> psk) {
    if (_psk == null || _step > 1) throw const NoiseError('not a psk handshake, or too late');
    if (psk.length != 32) throw ArgumentError('psk must be 32 bytes');
    _psk = Uint8List.fromList(psk);
  }

  /// The peer's static key (the initiator's, once message 1 was read).
  Uint8List? get remoteStatic => _rs;

  void _expect(int step, bool write) {
    final ok = _step == step && (write == (initiator == (step == 0)));
    if (!ok) throw const NoiseError('handshake message out of order');
  }

  /// Message 1 (initiator).
  Uint8List writeMessage1(List<int> payload) {
    _expect(0, true);
    final e = _e ??= DhKey.generate();
    final out = BytesBuilder(copy: false)..add(e.public);
    _ss.mixHash(e.public);
    if (_psk != null) _ss.mixKey(e.public);
    _ss.mixKey(x25519(e.private, _rs!));
    out.add(_ss.encryptAndHash(_s.public));
    _ss.mixKey(x25519(_s.private, _rs!));
    out.add(_ss.encryptAndHash(payload));
    _step = 1;
    return _checkLen(out.takeBytes());
  }

  /// Message 1 (responder): returns the payload. Throws [NoiseError].
  Uint8List readMessage1(List<int> msg) {
    _expect(0, false);
    if (msg.length < 32 + 32 + noiseTagLen + noiseTagLen) throw const NoiseError('message 1 too short');
    final re = _re = Uint8List.fromList(msg.sublist(0, 32));
    _ss.mixHash(re);
    if (_psk != null) _ss.mixKey(re);
    _ss.mixKey(x25519(_s.private, re));
    final rs = _rs = _ss.decryptAndHash(msg.sublist(32, 32 + 32 + noiseTagLen));
    _ss.mixKey(x25519(_s.private, rs));
    final payload = _ss.decryptAndHash(msg.sublist(32 + 32 + noiseTagLen));
    _step = 1;
    return payload;
  }

  /// Message 2 (responder): returns the message and the transport.
  (Uint8List, NoiseTransport) writeMessage2(List<int> payload) {
    _expect(1, true);
    final e = _e ??= DhKey.generate();
    final out = BytesBuilder(copy: false)..add(e.public);
    _ss.mixHash(e.public);
    if (_psk != null) _ss.mixKey(e.public);
    _ss.mixKey(x25519(e.private, _re!));
    _ss.mixKey(x25519(e.private, _rs!));
    if (_psk case final psk?) _ss.mixKeyAndHash(psk);
    out.add(_ss.encryptAndHash(payload));
    _step = 2;
    final (c1, c2) = _ss.split();
    // c1 carries initiator → responder.
    return (_checkLen(out.takeBytes()), NoiseTransport(c2, c1));
  }

  /// Message 2 (initiator): returns the payload and the transport. Throws
  /// [NoiseError] (a wrong psk or host key fails here).
  (Uint8List, NoiseTransport) readMessage2(List<int> msg) {
    _expect(1, false);
    if (msg.length < 32 + noiseTagLen) throw const NoiseError('message 2 too short');
    final re = _re = Uint8List.fromList(msg.sublist(0, 32));
    _ss.mixHash(re);
    if (_psk != null) _ss.mixKey(re);
    _ss.mixKey(x25519(_e!.private, re));
    _ss.mixKey(x25519(_s.private, re));
    if (_psk case final psk?) _ss.mixKeyAndHash(psk);
    final payload = _ss.decryptAndHash(msg.sublist(32));
    _step = 2;
    final (c1, c2) = _ss.split();
    return (payload, NoiseTransport(c1, c2));
  }

  static Uint8List _checkLen(Uint8List b) {
    if (b.length > noiseMaxMsg) throw const NoiseError('message too long');
    return b;
  }
}
