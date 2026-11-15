// Trusted host key fingerprints (trust on first use).
//
// The source of truth is HostConfig.hostKeyFingerprint, which the hosts
// repository persists with the rest of the host. A HostKeyStore is an
// optional second place: SshConnector consults it when the config carries no
// fingerprint and records newly accepted fingerprints in it, so callers that
// do not round-trip the config (tests, ad-hoc connects) still get TOFU.

import 'package:shared_preferences/shared_preferences.dart';

abstract class HostKeyStore {
  /// Trusted fingerprint for [hostId], or null when the host is unknown.
  Future<String?> get(String hostId);
  Future<void> put(String hostId, String fingerprint);
  Future<void> remove(String hostId);
}

class MemoryHostKeyStore implements HostKeyStore {
  final _m = <String, String>{};

  @override
  Future<String?> get(String hostId) async => _m[hostId];

  @override
  Future<void> put(String hostId, String fingerprint) async => _m[hostId] = fingerprint;

  @override
  Future<void> remove(String hostId) async => _m.remove(hostId);
}

/// [HostKeyStore] in shared_preferences (fingerprints are public data).
class PrefsHostKeyStore implements HostKeyStore {
  PrefsHostKeyStore([SharedPreferencesAsync? prefs]) : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;

  static String _k(String hostId) => 'agentd.ssh.hostkey.$hostId';

  @override
  Future<String?> get(String hostId) => _prefs.getString(_k(hostId));

  @override
  Future<void> put(String hostId, String fingerprint) => _prefs.setString(_k(hostId), fingerprint);

  @override
  Future<void> remove(String hostId) => _prefs.remove(_k(hostId));
}
