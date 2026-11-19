// Client side of the relay transport (Go internal/relayclient): pairing
// through an invite link, and a reconnecting tunnel whose streams are daemon
// connections ([ByteChannel]s for AgentdClient).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/contracts.dart';
import 'msg_conn.dart';
import 'mux.dart';
import 'noise.dart';
import 'wire.dart';

/// Opens a raw tunnel to [route] through the relay at [relayUrl].
typedef RelayMsgDial = Future<MsgConn> Function(String relayUrl, String route);

Future<MsgConn> _wsDial(String relayUrl, String route) => WsMsgConn.dialTunnel(relayUrl, route);

/// An established Noise transport over a [MsgConn].
class SecureConn implements MuxTransport {
  SecureConn(this._c, this._t);

  final MsgConn _c;
  final NoiseTransport _t;

  @override
  void send(Uint8List plain) {
    if (plain.length > noiseMaxMsg - noiseTagLen) throw ArgumentError('relay: message too long');
    _c.write(_t.send.encrypt(plain));
  }

  @override
  Future<Uint8List?> recv() async {
    final m = await _c.read();
    if (m == null) return null;
    try {
      return _t.recv.decrypt(m);
    } on NoiseError {
      throw const RelayError(RelayFailure.protocol, 'decrypt failed');
    }
  }

  void sendJson(Object v) => send(Uint8List.fromList(utf8.encode(jsonEncode(v))));

  Future<Map<String, Object?>?> recvJson() async {
    final b = await recv();
    if (b == null) return null;
    try {
      return (jsonDecode(utf8.decode(b)) as Map).cast<String, Object?>();
    } catch (_) {
      throw const RelayError(RelayFailure.protocol, 'bad JSON message');
    }
  }

  @override
  Future<void> close() => _c.close();
}

/// Runs the initiator side of the handshake on [c]. [psk] = the invite code
/// for a pairing, null for a paired device. Throws [RelayError].
Future<(SecureConn, RelayWelcome)> clientHandshake(
  MsgConn c, {
  required String route,
  required List<int> hostKey,
  required DhKey device,
  required Uint8List hello,
  Uint8List? psk,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final hs = IkHandshake.initiator(static: device, remoteStatic: hostKey, prologue: relayPrologue(route), psk: psk);
  c.write(hs.writeMessage1(hello));
  final Uint8List? msg2;
  try {
    msg2 = await c.read().timeout(timeout);
  } on TimeoutException {
    throw const RelayError(RelayFailure.hostNoAnswer, 'the host did not answer the handshake');
  }
  if (msg2 == null) {
    // The host closes without answering a handshake it cannot accept (an
    // unknown invite, or a key it does not know with a psk-less hello).
    throw psk != null
        ? const RelayError(RelayFailure.handshake, 'invite refused (unknown, used or expired)')
        : const RelayError(RelayFailure.handshake, 'the host closed the handshake');
  }
  final Uint8List payload;
  final NoiseTransport t;
  try {
    (payload, t) = hs.readMessage2(msg2);
  } on NoiseError {
    throw psk != null
        ? const RelayError(RelayFailure.handshake, 'handshake failed (wrong, used or expired invite?)')
        : const RelayError(RelayFailure.handshake, 'handshake failed (did the host key change?)');
  }
  final RelayWelcome w;
  try {
    w = RelayWelcome.fromJson((jsonDecode(utf8.decode(payload)) as Map).cast<String, Object?>());
  } catch (_) {
    throw const RelayError(RelayFailure.protocol, 'bad welcome');
  }
  if (!w.ok) {
    throw RelayError(RelayFailure.refused, w.error.isEmpty ? 'the host refused the device' : w.error, code: w.code);
  }
  return (SecureConn(c, t), w);
}

/// Result of a successful pairing.
class RelayPaired {
  const RelayPaired(this.device, this.host);
  final RelayDevice device;
  final String host; // host label
}

/// A paired host as the client stores it.
class RelayTarget {
  const RelayTarget({required this.relayUrl, required this.route, required this.hostKey, required this.device, this.name = '', this.platform = ''});

  final String relayUrl;
  final String route;
  final Uint8List hostKey; // pinned host X25519 public key
  final DhKey device;
  final String name;
  final String platform;
}

/// One established tunnel to a host.
class RelayTunnel {
  RelayTunnel(this.mux, this.welcome);

  final RelayMux mux;
  final RelayWelcome welcome;

  /// A new stream: one daemon connection.
  RelayStream open() => mux.open();

  Future<void> get done => mux.done;
  bool get isClosed => mux.isClosed;

  Future<void> close() => mux.close();
}

class RelayClient {
  RelayClient({RelayMsgDial? dial, this.handshakeTimeout = const Duration(seconds: 20)}) : _dial = dial ?? _wsDial;

  final RelayMsgDial _dial;
  final Duration handshakeTimeout;

  /// Redeems [inv] with the device key [device]. [onPending] is called once
  /// the host accepted the handshake and waits for a human approval. Throws
  /// [RelayError] ([RelayFailure.denied] when the host said no).
  Future<RelayPaired> pair(
    RelayInvite inv,
    DhKey device, {
    required String name,
    required String platform,
    void Function()? onPending,
    Duration approvalTimeout = const Duration(minutes: 15),
  }) async {
    final c = await _dial(inv.relayUrl, inv.route);
    try {
      final hello = encodeHello(mode: relayModePair, invite: inv.id, name: name, platform: platform);
      final (sec, _) = await clientHandshake(c, route: inv.route, hostKey: inv.hostKey, device: device, hello: hello, psk: inv.code, timeout: handshakeTimeout);
      sec.sendJson({'t': 'confirm'});
      onPending?.call();
      final Map<String, Object?>? m;
      try {
        m = await sec.recvJson().timeout(approvalTimeout);
      } on TimeoutException {
        throw const RelayError(RelayFailure.denied, 'no approval from the host in time');
      }
      if (m == null) throw const RelayError(RelayFailure.denied, 'the host closed the pairing');
      switch (m['t']) {
        case 'paired' when m['device'] is Map:
          return RelayPaired(RelayDevice.fromJson((m['device'] as Map).cast<String, Object?>()), m['host'] as String? ?? '');
        case 'denied':
          final e = m['error'] as String? ?? '';
          throw RelayError(RelayFailure.denied, e.isEmpty ? 'pairing denied' : e);
      }
      throw const RelayError(RelayFailure.protocol, 'unexpected pairing answer');
    } finally {
      await c.close();
    }
  }

  /// Opens a tunnel to a paired host. Throws [RelayError].
  Future<RelayTunnel> connect(RelayTarget t) async {
    final c = await _dial(t.relayUrl, t.route);
    try {
      final hello = encodeHello(mode: relayModeConnect, name: t.name, platform: t.platform);
      final (sec, w) = await clientHandshake(c, route: t.route, hostKey: t.hostKey, device: t.device, hello: hello, timeout: handshakeTimeout);
      return RelayTunnel(RelayMux.client(sec), w);
    } catch (_) {
      await c.close();
      rethrow;
    }
  }
}

/// Keeps one tunnel to a host and reopens it when it dropped. [open] returns
/// a fresh stream on the live tunnel.
class RelayDialer {
  RelayDialer(this.client, this.target);

  final RelayClient client;
  final RelayTarget target;
  RelayTunnel? _cur;
  Future<RelayTunnel>? _connecting;

  /// The live tunnel, if any.
  RelayTunnel? get current => _cur != null && !_cur!.isClosed ? _cur : null;

  /// The live tunnel, connecting first if needed.
  Future<RelayTunnel> tunnel() {
    final cur = current;
    if (cur != null) return Future.value(cur);
    return _connecting ??= () async {
      try {
        final t = await client.connect(target);
        _cur = t;
        return t;
      } finally {
        _connecting = null;
      }
    }();
  }

  /// A new daemon connection, connecting first if needed (one retry when
  /// the tunnel died between the check and the open).
  Future<ByteChannel> open() async {
    var t = await tunnel();
    try {
      return t.open();
    } on RelayError {
      if (identical(_cur, t)) _cur = null;
      t = await tunnel();
      return t.open();
    }
  }

  Future<void> close() async {
    final t = _cur;
    _cur = null;
    await t?.close();
  }
}
