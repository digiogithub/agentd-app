// PushRepository over agentd: ops push_register / push_unregister on the
// host's daemon, through SSH or the relay tunnel. The token is never logged.

import 'dart:io' show Platform;

import '../core/contracts.dart';
import 'agentd_clients.dart';

class AgentdPushRepository implements PushRepository {
  AgentdPushRepository({required this._clients, String? platform}) : _platform = platform ?? _thisPlatform();

  final AgentdClients _clients;
  final String _platform;

  static String _thisPlatform() {
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
    } catch (_) {}
    return 'other';
  }

  @override
  Future<bool> register(String hostId, {required String token, required String deviceName}) async {
    try {
      final c = await _clients.forHost(hostId);
      if (c == null) return false;
      final name = deviceName.length > 64 ? deviceName.substring(0, 64) : deviceName;
      await c.pushRegister(token: token, platform: _platform, name: name, hostRef: hostId);
      return true;
    } catch (_) {
      // An older daemon (unknown op), a guest device (forbidden) or a broken
      // connection: no push from this host, nothing to show.
      return false;
    }
  }

  @override
  Future<void> unregister(String hostId, {required String token}) async {
    try {
      final c = await _clients.forHost(hostId);
      if (c == null) return;
      await c.pushUnregister(token: token);
    } catch (_) {}
  }
}
