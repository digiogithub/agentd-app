// Interop proof: the Dart Noise reproduces the Go vectors
// (agentd internal/relaywire/testdata/noise_vectors.json, copied here) byte
// for byte, as initiator and as responder.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agentd_app/src/relay/noise.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

void main() {
  final vectors = (jsonDecode(File('test/relay/testdata/noise_vectors.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();

  test('the fixture has both patterns', () {
    expect(vectors.map((v) => v['protocol']), [IkHandshake.protocolIK, IkHandshake.protocolIKpsk2]);
  });

  for (final v in vectors) {
    final name = v['name'] as String;
    final psk = v['psk_hex'] == null ? null : _hex(v['psk_hex'] as String);
    final prologue = _hex(v['prologue_hex'] as String);
    final initS = DhKey.fromPrivate(_hex(v['init_static_private_hex'] as String));
    final initE = DhKey.fromPrivate(_hex(v['init_ephemeral_private_hex'] as String));
    final respS = DhKey.fromPrivate(_hex(v['resp_static_private_hex'] as String));
    final respE = DhKey.fromPrivate(_hex(v['resp_ephemeral_private_hex'] as String));
    final payload1 = _hex(v['payload1_hex'] as String);
    final payload2 = _hex(v['payload2_hex'] as String);
    final msg1 = _hex(v['msg1_hex'] as String);
    final msg2 = _hex(v['msg2_hex'] as String);
    final c2sPlain = _hex(v['transport_c2s_plain_hex'] as String);
    final c2sMsg = _hex(v['transport_c2s_msg_hex'] as String);
    final s2cPlain = _hex(v['transport_s2c_plain_hex'] as String);
    final s2cMsg = _hex(v['transport_s2c_msg_hex'] as String);

    test('$name initiator matches the Go vectors', () {
      final hs = IkHandshake.initiator(static: initS, remoteStatic: respS.public, prologue: prologue, psk: psk, ephemeral: initE);
      expect(hs.writeMessage1(payload1), msg1);
      final (p2, t) = hs.readMessage2(msg2);
      expect(p2, payload2);
      expect(t.send.encrypt(c2sPlain), c2sMsg);
      expect(t.recv.decrypt(s2cMsg), s2cPlain);
    });

    test('$name responder matches the Go vectors', () {
      final hs = IkHandshake.responder(static: respS, prologue: prologue, psk: psk, ephemeral: respE);
      expect(hs.readMessage1(msg1), payload1);
      expect(hs.remoteStatic, initS.public);
      final (m2, t) = hs.writeMessage2(payload2);
      expect(m2, msg2);
      expect(t.recv.decrypt(c2sMsg), c2sPlain);
      expect(t.send.encrypt(s2cPlain), s2cMsg);
    });
  }

  test('a wrong psk fails at message 2', () {
    final client = DhKey.generate();
    final host = DhKey.generate();
    final good = Uint8List(32)..fillRange(0, 32, 7);
    final bad = Uint8List(32)..fillRange(0, 32, 8);
    final i = IkHandshake.initiator(static: client, remoteStatic: host.public, prologue: const [1], psk: good);
    final r = IkHandshake.responder(static: host, prologue: const [1], psk: bad);
    // psk2: message 1 does not depend on the psk value.
    expect(r.readMessage1(i.writeMessage1(const [])), isEmpty);
    final (m2, _) = r.writeMessage2(const [1, 2, 3]);
    expect(() => i.readMessage2(m2), throwsA(isA<NoiseError>()));
  });

  test('IK and IKpsk2 message 1 are not interchangeable', () {
    final client = DhKey.generate();
    final host = DhKey.generate();
    final i = IkHandshake.initiator(static: client, remoteStatic: host.public, prologue: const [], psk: Uint8List(32));
    final r = IkHandshake.responder(static: host, prologue: const []);
    expect(() => r.readMessage1(i.writeMessage1(const [9])), throwsA(isA<NoiseError>()));
  });

  test('a tampered transport message is refused and the nonce does not advance', () {
    final client = DhKey.generate();
    final host = DhKey.generate();
    final i = IkHandshake.initiator(static: client, remoteStatic: host.public, prologue: const []);
    final r = IkHandshake.responder(static: host, prologue: const []);
    r.readMessage1(i.writeMessage1(const []));
    final (m2, rt) = r.writeMessage2(const []);
    final (_, it) = i.readMessage2(m2);
    final ct = it.send.encrypt([1, 2, 3]);
    final bad = Uint8List.fromList(ct)..[0] ^= 1;
    expect(() => rt.recv.decrypt(bad), throwsA(isA<NoiseError>()));
    expect(rt.recv.decrypt(ct), [1, 2, 3]);
  });
}
