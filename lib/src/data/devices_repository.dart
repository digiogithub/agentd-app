// DevicesRepository over agentd: op relay (devices, revoke) on the host's
// daemon, through SSH or the relay tunnel.

import '../agentd/agentd.dart';
import '../core/contracts.dart';
import 'agentd_clients.dart';

class AgentdDevicesRepository implements DevicesRepository {
  AgentdDevicesRepository({required this._hosts, required this._clients});

  final HostsRepository _hosts;
  final AgentdClients _clients;

  /// This app's device id on [hostId] (null for an SSH host).
  Future<String?> _ownId(String hostId) async {
    final list = await _hosts.watch().first;
    return list.where((h) => h.config.id == hostId).firstOrNull?.config.relay?.deviceId;
  }

  Future<T> _run<T>(String hostId, Future<T> Function(AgentdClient c) op) async {
    final c = await _clients.forHost(hostId);
    if (c == null) throw const DevicesException(DevicesFailure.unavailable, 'no reachable agentd');
    try {
      return await op(c);
    } on AgentdError catch (e) {
      throw DevicesException(switch (e.code) {
        AgentdErrorCode.forbidden => DevicesFailure.forbidden,
        AgentdErrorCode.notFound => DevicesFailure.notFound,
        _ => DevicesFailure.unavailable,
      }, e.message);
    } on DevicesException {
      rethrow;
    } catch (e) {
      throw DevicesException(DevicesFailure.unavailable, '${e.runtimeType}');
    }
  }

  @override
  Future<List<PairedDevice>> devices(String hostId) async {
    final own = await _ownId(hostId);
    final list = await _run(hostId, (c) => c.relayDevices());
    final out = [
      for (final d in list)
        PairedDevice(
          id: d.id,
          name: d.name,
          platform: d.platform,
          scope: RelayScope.parse(d.scope),
          sessions: d.sessions,
          guest: d.kind == 'guest',
          createdAt: d.createdAt,
          expiresAt: d.expiresAt,
          lastSeen: d.lastSeen,
          online: d.online,
          isThisDevice: own != null && d.id == own,
        ),
    ];
    // This device first, then the connected ones, then by name.
    int rank(PairedDevice d) => d.isThisDevice ? 0 : (d.online ? 1 : 2);
    out.sort((a, b) => rank(a) != rank(b) ? rank(a) - rank(b) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  @override
  Future<void> revoke(String hostId, String deviceId) async {
    final own = await _ownId(hostId);
    await _run(hostId, (c) => c.relayRevoke(deviceId));
    // The host closes this device's tunnel right after its answer and will
    // refuse it from now on: the saved host (and its device key) is useless.
    if (own != null && deviceId == own) await _hosts.remove(hostId);
  }
}
