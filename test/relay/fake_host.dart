// In-memory relay + host for tests: follows protocol v1 like the Go daemon
// (internal/relaywire ServerHandshake, the pairing exchange, the host mux).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/relay/relay.dart';

/// Serves one accepted stream.
typedef StreamHandler = FutureOr<void> Function(RelayStream s);

class FakeRelayHost {
  FakeRelayHost({this.label = 'box', this.route = 'abcdefghijklmnopqrstuvwxyz'}) : key = DhKey.generate();

  final String label;
  final String route;
  final DhKey key;

  /// Live invites: id → code.
  final Map<String, Uint8List> invites = {};

  /// Paired devices by public key (b64url).
  final Map<String, RelayDevice> devices = {};

  /// Pairing decision (null = approve). Awaited after the confirm.
  Future<bool> Function(Map<String, Object?> hello)? approve;

  /// Scope / sessions given to newly paired devices.
  String scope = 'operate';
  List<String> sessions = const [];

  /// Offline = the relay closes tunnels with 4404.
  bool online = true;

  StreamHandler onStream = _echo;
  final List<Map<String, Object?>> hellos = [];
  final List<RelayMux> muxes = [];
  int tunnels = 0;
  bool sawConfirm = false;

  static Future<void> _echo(RelayStream s) async {
    await for (final b in s.stream) {
      s.add(b);
    }
    await s.close();
  }

  /// A [RelayMsgDial] that reaches this host.
  Future<MsgConn> dial(String relayUrl, String route) async {
    final (client, server) = MemoryMsgConn.pair();
    if (!online || route != this.route) {
      unawaited(server.closeWith(4404));
      return client;
    }
    tunnels++;
    unawaited(serve(server));
    return client;
  }

  Uint8List invite(String id, {Uint8List? code}) => invites[id] = code ?? Uint8List.fromList(List.generate(32, (i) => i * 7 + 1));

  RelayInvite inviteLink(String id) =>
      RelayInvite(relayUrl: 'https://relay.example', route: route, hostKey: key.public, id: id, code: invites[id] ?? invite(id), label: label);

  /// Serves one tunnel (the host side of a relay connect).
  Future<void> serve(MsgConn c) async {
    final msg1 = await c.read();
    if (msg1 == null) return;
    IkHandshake? hs;
    Map<String, Object?>? hello;
    var isPsk = false;
    for (final psk in [false, true]) {
      final cand = IkHandshake.responder(static: key, prologue: relayPrologue(route), psk: psk ? Uint8List(32) : null);
      try {
        final p = cand.readMessage1(msg1);
        hello = (jsonDecode(utf8.decode(p)) as Map).cast<String, Object?>();
        hs = cand;
        isPsk = psk;
        break;
      } catch (_) {}
    }
    if (hs == null || hello == null) {
      await c.close();
      return;
    }
    hellos.add(hello);
    final clientPub = b64url(hs.remoteStatic!);
    final mode = hello['mode'];
    if (isPsk != (mode == relayModePair)) {
      await c.close();
      return;
    }
    if (isPsk) {
      final code = invites.remove(hello['invite']);
      if (code == null) {
        await c.close(); // the client cannot read an answer anyway
        return;
      }
      hs.setPsk(code);
      final (m2, t) = hs.writeMessage2(utf8.encode(jsonEncode({'v': 1, 'ok': true, 'pending': true, 'host': label})));
      c.write(m2);
      final sec = SecureConn(c, t);
      final confirm = await sec.recvJson();
      sawConfirm = confirm?['t'] == 'confirm';
      final ok = await (approve?.call(hello) ?? Future.value(true));
      if (ok) {
        final d = RelayDevice(id: relayDeviceId(hs.remoteStatic!), scope: scope, sessions: sessions, kind: 'owner');
        devices[clientPub] = d;
        sec.sendJson({
          't': 'paired',
          'host': label,
          'device': {'id': d.id, 'scope': d.scope, 'sessions': d.sessions, 'kind': d.kind},
        });
      } else {
        sec.sendJson({'t': 'denied', 'error': 'denied by the host'});
      }
      await c.close();
      return;
    }
    final d = devices[clientPub];
    if (d == null) {
      final (m2, _) = hs.writeMessage2(utf8.encode(jsonEncode({'v': 1, 'ok': false, 'code': 'forbidden', 'error': 'unknown device'})));
      c.write(m2);
      await c.close();
      return;
    }
    final (m2, t) = hs.writeMessage2(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'ok': true,
          'host': label,
          'device': {'id': d.id, 'scope': d.scope, 'sessions': d.sessions, 'kind': d.kind},
        }),
      ),
    );
    c.write(m2);
    final mux = RelayMux.server(SecureConn(c, t));
    muxes.add(mux);
    mux.incoming.listen((s) => onStream(s));
  }

  /// Drops every live tunnel (the host link went away).
  Future<void> dropTunnels() async {
    for (final m in muxes) {
      await m.close();
    }
    muxes.clear();
  }
}

/// Bridges a relay stream to a ByteChannel (e.g. a fake daemon dial).
Future<void> bridge(RelayStream s, ByteChannel ch) async {
  final a = s.stream.listen(ch.add, onDone: () => ch.close());
  ch.stream.listen(
    s.add,
    onDone: () {
      unawaited(a.cancel());
      unawaited(s.close());
    },
  );
}
