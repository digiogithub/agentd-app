// Saved hosts. Only HostConfig goes here (no secrets: keys and passwords
// live in the secure store), so shared_preferences is enough.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/contracts.dart';

abstract class HostStore {
  Future<List<HostConfig>> load();

  /// Replaces the whole list (order kept).
  Future<void> saveAll(List<HostConfig> hosts);
}

class MemoryHostStore implements HostStore {
  MemoryHostStore([List<HostConfig> hosts = const []]) : hosts = [...hosts];
  List<HostConfig> hosts;

  @override
  Future<List<HostConfig>> load() async => [...hosts];

  @override
  Future<void> saveAll(List<HostConfig> hosts) async => this.hosts = [...hosts];
}

/// [HostStore] in shared_preferences, as one JSON list.
class PrefsHostStore implements HostStore {
  PrefsHostStore([SharedPreferencesAsync? prefs]) : _prefs = prefs ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _prefs;
  static const key = 'agentd.hosts.v1';

  @override
  Future<List<HostConfig>> load() async {
    final raw = await _prefs.getString(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return [for (final j in list) HostConfig.fromJson((j as Map).cast<String, Object?>())];
    } catch (_) {
      // A corrupt value must not brick the app: start empty, keep the raw
      // value aside for a later look.
      await _prefs.setString('$key.bad', raw);
      return [];
    }
  }

  @override
  Future<void> saveAll(List<HostConfig> hosts) => _prefs.setString(key, jsonEncode([for (final h in hosts) h.toJson()]));
}
