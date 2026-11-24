import 'dart:typed_data';

import 'package:agentd_app/src/core/contracts.dart' show relayLinkCandidates;
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

  group('pasted or scanned text', () {
    final plain = link({});
    void same(String text) {
      final inv = RelayInvite.parse(text);
      expect(inv.toString(), RelayInvite.parse(plain).toString(), reason: 'input of ${text.length} chars');
    }

    test('whitespace and newlines around the link', () {
      same('  $plain  ');
      same('\n\t$plain\r\n');
    });

    test('the "Link:" line of agentd relay invite, with what follows', () {
      same('Link:  $plain');
      same('Link:  $plain\nGrant: operate (owner); valid until 21:40:00. Waiting for a device (Ctrl-C cancels)...\n');
      same('usa este enlace: $plain y dime');
      same('<$plain>');
      same('"$plain"');
      same('Enlace ($plain).');
    });

    test('terminal line wraps anywhere in the link', () {
      for (final at in [20, 60, 100, 140, plain.length - 2]) {
        same('${plain.substring(0, at)}\n${plain.substring(at)}');
        same('Link:  ${plain.substring(0, at)}  \r\n   ${plain.substring(at)}\n');
      }
      // Three lines of 40 columns.
      final lines = [for (var i = 0; i < plain.length; i += 40) plain.substring(i, i + 40 > plain.length ? plain.length : i + 40)];
      same(lines.join('\n'));
    });

    test('a wrapped link followed by other text keeps the secret fields', () {
      final at = plain.indexOf('&c=') + 10;
      final inv = RelayInvite.parse('Link:  ${plain.substring(0, at)}\n${plain.substring(at)}\nGrant: view');
      expect(inv.code, code);
      expect(inv.route, 'abcdefghijklmnopqrstuvwx27');
    });

    test('url-encoded parameters are decoded', () {
      final inv = RelayInvite.parse(link({'u': 'https://relay.example.com/a b', 'h': 'café de José & co'}));
      expect(inv.relayUrl, 'https://relay.example.com/a b');
      expect(inv.label, 'café de José & co');
      expect(RelayInvite.parse(plain.replaceFirst('https%3A%2F%2F', 'https://')).relayUrl, 'https://relay.example.com');
      // An upper-case scheme (some QR readers) is the same link.
      same(plain.replaceFirst('agentd://', 'AGENTD://'));
    });

    test('the first link wins and a cut link is refused', () {
      same('$plain agentd://relay?v=1&u=x');
      expect(() => RelayInvite.parse(plain.substring(0, plain.indexOf('&c=') + 12)), throwsA(isA<InviteFormatError>()));
      expect(() => RelayInvite.parse('agentd://relay?'), throwsA(isA<InviteFormatError>()));
    });

    test('candidates: wrapped lines joined first, the first line alone second', () {
      expect(relayLinkCandidates('nothing here'), isEmpty);
      expect(relayLinkCandidates('x agentd://relay?v=1&h=a. y'), ['agentd://relay?v=1&h=a']);
      // A line with other text does not continue the link.
      expect(relayLinkCandidates('agentd://relay?v=1\n&h=a z'), ['agentd://relay?v=1']);
      expect(relayLinkCandidates('agentd://relay?v=1\n&h=a\nz z'), ['agentd://relay?v=1&h=a', 'agentd://relay?v=1']);
      expect(relayLinkCandidates('agentd://relay?v=1 x\n&h=a'), ['agentd://relay?v=1']);
    });

    test('a single word on the next line cannot break the secret fields', () {
      final noLabel = link({'h': null});
      expect(RelayInvite.parse('$noLabel\nCancelled').code, code);
    });
  });

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
