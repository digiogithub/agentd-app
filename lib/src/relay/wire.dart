// Relay protocol v1 data (agentd docs/plans/agentd/relay_plan.md and Go
// internal/relaywire): ids, the invite link, handshake payloads and errors.

import 'dart:convert';
import 'dart:io' show InternetAddress;
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

/// WebSocket subprotocol of every relay endpoint.
const relaySubprotocol = 'agentd-relay.v1';

/// The Noise prologue starts with this; the route id follows.
const relayProloguePrefix = 'agentd-relay/1\n';

/// Length of a route id.
const relayRouteLen = 26;

/// Noise prologue of a tunnel to [route].
Uint8List relayPrologue(String route) => Uint8List.fromList(utf8.encode('$relayProloguePrefix$route'));

/// base64url without padding (the protocol's flavour everywhere).
String b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');

/// Inverse of [b64url]; throws [FormatException]. Padding is refused, as
/// Go's RawURLEncoding does.
Uint8List unb64url(String s) {
  if (s.contains('=') || s.contains('+') || s.contains('/')) throw const FormatException('not raw base64url');
  return base64Url.decode(s.padRight((s.length + 3) & ~3, '='));
}

const _b32 = 'abcdefghijklmnopqrstuvwxyz234567';

/// Lowercase base32 (RFC 4648 alphabet) without padding.
String base32Lower(List<int> data) {
  final out = StringBuffer();
  var buf = 0, bits = 0;
  for (final b in data) {
    buf = (buf << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_b32[(buf >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buf &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_b32[(buf << (5 - bits)) & 31]);
  return out.toString();
}

/// Device id of an X25519 public key: `d` + 12 chars of base32(SHA-256).
String relayDeviceId(List<int> pub) => 'd${base32Lower(const DartSha256().hashSync(pub).bytes).substring(0, 12)}';

/// Whether [s] has the shape of a route id.
bool validRoute(String s) => s.length == relayRouteLen && RegExp(r'^[a-z2-7]+$').hasMatch(s);

/// Whether [s] is a 16-char lowercase hex invite id.
bool validInviteId(String s) => RegExp(r'^[0-9a-f]{16}$').hasMatch(s);

/// A refused or malformed invite / relay URL.
class InviteFormatError implements Exception {
  const InviteFormatError(this.message);
  final String message;

  @override
  String toString() => 'InviteFormatError: $message';
}

/// Accepts https/wss relay URLs, and http/ws only for loopback hosts, with
/// no credentials, query or fragment (Go `CheckRelayURL`).
void checkRelayUrl(String s) {
  final Uri u;
  try {
    u = Uri.parse(s);
  } on FormatException {
    throw const InviteFormatError('relay url: invalid');
  }
  if (u.host.isEmpty) throw const InviteFormatError('relay url: invalid');
  if (u.userInfo.isNotEmpty || u.hasQuery || u.hasFragment) {
    throw const InviteFormatError('relay url: must not carry credentials, query or fragment');
  }
  switch (u.scheme) {
    case 'https' || 'wss':
      return;
    case 'http' || 'ws':
      if (isLoopbackHost(u.host)) return;
      throw const InviteFormatError('relay url: plain http/ws is only allowed on loopback');
    default:
      throw const InviteFormatError('relay url: scheme must be https or wss');
  }
}

bool isLoopbackHost(String host) {
  if (host == 'localhost') return true;
  final ip = InternetAddress.tryParse(host);
  return ip != null && ip.isLoopback;
}

/// The WebSocket URL of endpoint [path] (`/v1/connect`) on relay [base].
String relayEndpoint(String base, String path, Map<String, String> query) {
  final u = Uri.parse(base);
  final scheme = switch (u.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    final s => s,
  };
  var p = u.path;
  while (p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return u.replace(scheme: scheme, path: '$p$path', queryParameters: query).toString();
}

/// An invite link `agentd://relay?v=1&u=…&r=…&k=…&i=…&c=…&h=…`. [code] is a
/// secret (the Noise psk): never log it, never keep it after pairing.
class RelayInvite {
  const RelayInvite({required this.relayUrl, required this.route, required this.hostKey, required this.id, required this.code, this.label = ''});

  final String relayUrl;
  final String route;
  final Uint8List hostKey; // host X25519 public key
  final String id; // invite id (not secret)
  final Uint8List code; // 32 bytes, secret
  final String label;

  /// Parses and validates a link (Go `ParseInvite`). Throws
  /// [InviteFormatError]; the message never contains the code.
  static RelayInvite parse(String link) {
    final Uri u;
    try {
      u = Uri.parse(link.trim());
    } on FormatException {
      throw const InviteFormatError('invite: not an agentd relay link');
    }
    if (u.scheme != 'agentd' || u.host != 'relay') throw const InviteFormatError('invite: not an agentd relay link');
    final Map<String, String> q;
    try {
      q = u.queryParameters;
    } on FormatException {
      throw const InviteFormatError('invite: bad query');
    }
    if (q['v'] != '1') throw const InviteFormatError('invite: unsupported version');
    final relayUrl = q['u'] ?? '';
    checkRelayUrl(relayUrl);
    final route = q['r'] ?? '';
    if (!validRoute(route)) throw const InviteFormatError('invite: bad route');
    final hostKey = _key(q['k']);
    if (hostKey == null) throw const InviteFormatError('invite: bad host key');
    final code = _key(q['c']);
    if (code == null) throw const InviteFormatError('invite: bad code');
    final id = q['i'] ?? '';
    if (!validInviteId(id)) throw const InviteFormatError('invite: bad invite id');
    final label = q['h'] ?? '';
    if (utf8.encode(label).length > 64) throw const InviteFormatError('invite: label too long');
    return RelayInvite(relayUrl: relayUrl, route: route, hostKey: hostKey, id: id, code: code, label: label);
  }

  static Uint8List? _key(String? s) {
    if (s == null) return null;
    try {
      final b = unb64url(s);
      return b.length == 32 ? b : null;
    } on FormatException {
      return null;
    }
  }

  /// The link again (fixed field order, as Go renders it).
  @override
  String toString() {
    final parts = <String>[
      'v=1',
      'u=${Uri.encodeQueryComponent(relayUrl)}',
      'r=$route',
      'k=${b64url(hostKey)}',
      'i=$id',
      'c=${b64url(code)}',
      if (label.isNotEmpty) 'h=${Uri.encodeQueryComponent(label)}',
    ];
    return 'agentd://relay?${parts.join('&')}';
  }
}

/// Handshake modes.
const relayModeConnect = 'connect';
const relayModePair = 'pair';

/// Permission scopes of a device, lowest first.
const relayScopes = ['view', 'operate', 'admin'];

/// A paired device as the host reports it.
class RelayDevice {
  const RelayDevice({required this.id, required this.scope, this.name = '', this.sessions = const [], this.kind = ''});

  final String id;
  final String name;
  final String scope; // view | operate | admin
  final List<String> sessions; // name globs; empty = all
  final String kind; // owner | guest

  factory RelayDevice.fromJson(Map<String, Object?> j) => RelayDevice(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    scope: j['scope'] as String? ?? '',
    sessions: [for (final s in (j['sessions'] as List?) ?? const []) s as String],
    kind: j['kind'] as String? ?? '',
  );
}

/// Message 1 payload (client → host).
Uint8List encodeHello({required String mode, String invite = '', String name = '', String platform = ''}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'v': 1,
      'mode': mode,
      if (invite.isNotEmpty) 'invite': invite,
      if (name.isNotEmpty) 'name': name,
      if (platform.isNotEmpty) 'platform': platform,
    }),
  ),
);

/// Message 2 payload (host → client).
class RelayWelcome {
  const RelayWelcome({required this.ok, this.pending = false, this.host = '', this.device, this.code = '', this.error = ''});

  final bool ok;
  final bool pending;
  final String host;
  final RelayDevice? device;
  final String code;
  final String error;

  factory RelayWelcome.fromJson(Map<String, Object?> j) => RelayWelcome(
    ok: j['ok'] == true,
    pending: j['pending'] == true,
    host: j['host'] as String? ?? '',
    device: j['device'] is Map ? RelayDevice.fromJson((j['device'] as Map).cast<String, Object?>()) : null,
    code: j['code'] as String? ?? '',
    error: j['error'] as String? ?? '',
  );
}

/// What can go wrong reaching a host through a relay.
enum RelayFailure {
  /// The relay has no link for the host (close 4404).
  hostOffline,

  /// The host did not take the tunnel in time (4504).
  hostNoAnswer,

  /// Too many attempts from this address (4429).
  rateLimited,

  /// Too many tunnels to this host (4503).
  tooManyTunnels,

  /// The relay could not be reached (DNS, TCP, TLS, HTTP upgrade).
  unreachable,

  /// The Noise handshake failed (wrong host key, or a wrong / used /
  /// expired invite).
  handshake,

  /// The host refused the device (revoked, unknown, forbidden...).
  refused,

  /// The host denied the pairing.
  denied,

  /// Protocol violation or the tunnel ended.
  protocol,
}

/// A relay error with a stable [failure] and an English [message] (no
/// secrets). [code] is the host's refusal code when there is one.
class RelayError implements Exception {
  const RelayError(this.failure, this.message, {this.code = ''});
  final RelayFailure failure;
  final String message;
  final String code;

  @override
  String toString() => 'RelayError(${failure.name}): $message';
}

/// Maps a relay close code to an error (null for other codes).
RelayError? relayCloseError(int? code) => switch (code) {
  4404 => const RelayError(RelayFailure.hostOffline, 'the host is not connected to the relay'),
  4504 => const RelayError(RelayFailure.hostNoAnswer, 'the host did not answer'),
  4429 => const RelayError(RelayFailure.rateLimited, 'too many connection attempts, retry later'),
  4503 => const RelayError(RelayFailure.tooManyTunnels, 'too many tunnels to this host'),
  _ => null,
};
