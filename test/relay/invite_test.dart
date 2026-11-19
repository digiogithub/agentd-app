import 'dart:typed_data';

import 'package:agentd_app/src/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final code = Uint8List.fromList(List.generate(32, (i) => 255 - i));
  final good = RelayInvite(
    relayUrl: 'https://relay.example.com/base',
    route: 'abcdefghijklmnopqrstuvwx27',
    hostKey: key,
    id: '0123456789abcdef',
    code: code,
    label: 'my box',
  );

  String link(Map<String, String?> over) {
    final q = {
      'v': '1',
      'u': 'https://relay.example.com',
      'r': 'abcdefghijklmnopqrstuvwx27',
      'k': b64url(key),
      'i': '0123456789abcdef',
      'c': b64url(code),
      'h': 'box',
      ...over,
    }..removeWhere((_, v) => v == null);
    return 'agentd://relay?${q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value!)}').join('&')}';
  }

  test('round trip of a valid link', () {
    final inv = RelayInvite.parse(good.toString());
    expect(inv.relayUrl, good.relayUrl);
    expect(inv.route, good.route);
    expect(inv.hostKey, key);
    expect(inv.code, code);
    expect(inv.id, good.id);
    expect(inv.label, 'my box');
    expect(good.toString(), startsWith('agentd://relay?v=1&u=https%3A%2F%2Frelay.example.com%2Fbase&r='));
  });

  test('a link Go renders parses (url-escaped relay, label with +)', () {
    final inv = RelayInvite.parse(
      '  agentd://relay?v=1&u=https%3A%2F%2Frelay.example.com&r=abcdefghijklmnopqrstuvwx27&k=${b64url(key)}&i=0123456789abcdef&c=${b64url(code)}&h=my+box\n',
    );
    expect(inv.label, 'my box');
    expect(inv.relayUrl, 'https://relay.example.com');
  });

  test('loopback http and ws are allowed', () {
    for (final u in ['http://127.0.0.1:8080', 'ws://localhost:1', 'http://[::1]:9']) {
      expect(RelayInvite.parse(link({'u': u})).relayUrl, u);
    }
    expect(RelayInvite.parse(link({'u': 'wss://r.example'})).relayUrl, 'wss://r.example');
    expect(RelayInvite.parse(link({'h': null})).label, '');
  });

  final bad = <String, Map<String, String?>>{
    'version': {'v': '2'},
    'no version': {'v': null},
    'plain http remote': {'u': 'http://relay.example.com'},
    'ftp': {'u': 'ftp://relay.example.com'},
    'credentials': {'u': 'https://user:pw@relay.example.com'},
    'query': {'u': 'https://relay.example.com/?x=1'},
    'fragment': {'u': 'https://relay.example.com/#x'},
    'no host': {'u': 'https://'},
    'short route': {'r': 'abc'},
    'route charset': {'r': 'ABCDEFGHIJKLMNOPQRSTUVWX27'},
    'route with 1': {'r': 'abcdefghijklmnopqrstuvwx21'},
    'key length': {'k': b64url(key.sublist(1))},
    'key padding': {'k': '${b64url(key)}='},
    'key std base64': {'k': '+/${b64url(key).substring(2)}'},
    'no code': {'c': null},
    'code length': {'c': b64url(code.sublist(0, 16))},
    'invite id': {'i': '0123456789ABCDEF'},
    'invite id length': {'i': '0123'},
    'label too long': {'h': 'x' * 65},
  };
  for (final e in bad.entries) {
    test('refuses: ${e.key}', () {
      expect(() => RelayInvite.parse(link(e.value)), throwsA(isA<InviteFormatError>()));
    });
  }

  test('refuses other links', () {
    for (final l in ['https://relay.example.com', 'agentd://pair?v=1', 'agentd://open?h=x', 'not a link at all', '']) {
      expect(() => RelayInvite.parse(l), throwsA(isA<InviteFormatError>()));
    }
  });

  test('error messages never carry the code', () {
    try {
      RelayInvite.parse(link({'i': 'nope'}));
      fail('parsed');
    } on InviteFormatError catch (e) {
      expect(e.toString(), isNot(contains(b64url(code))));
    }
  });

  test('ids and endpoints match the Go helpers', () {
    expect(base32Lower([0xff]), '74');
    expect(base32Lower('foobar'.codeUnits), 'mzxw6ytboi');
    expect(relayDeviceId(Uint8List(32)), hasLength(13));
    expect(relayDeviceId(Uint8List(32)), startsWith('d'));
    // Python: 'd' + b32encode(sha256(bytes(32))).lower()[:12]
    expect(relayDeviceId(Uint8List(32)), 'dmzuhvlpymk6x');
    expect(relayEndpoint('https://r.example/base/', '/v1/connect', {'route': 'abc'}), 'wss://r.example/base/v1/connect?route=abc');
    expect(relayEndpoint('http://127.0.0.1:8080', '/v1/connect', {'route': 'abc'}), 'ws://127.0.0.1:8080/v1/connect?route=abc');
    expect(relayEndpoint('wss://r.example', '/v1/connect', {'route': 'abc'}), 'wss://r.example/v1/connect?route=abc');
    expect(relayPrologue('abc'), 'agentd-relay/1\nabc'.codeUnits);
  });

  test('relay close codes map to errors', () {
    expect(relayCloseError(4404)!.failure, RelayFailure.hostOffline);
    expect(relayCloseError(4504)!.failure, RelayFailure.hostNoAnswer);
    expect(relayCloseError(4429)!.failure, RelayFailure.rateLimited);
    expect(relayCloseError(4503)!.failure, RelayFailure.tooManyTunnels);
    expect(relayCloseError(1000), isNull);
    expect(relayCloseError(null), isNull);
  });
}
