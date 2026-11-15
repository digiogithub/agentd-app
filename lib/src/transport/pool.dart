// One live RemoteShell per host, connected on demand.

import 'dart:async';

import '../core/contracts.dart';
import 'connector.dart';
import 'host_key_store.dart';
import 'key_store.dart';

typedef ShellConnect = Future<RemoteShell> Function(HostConfig config);

/// Keeps at most one connection per host id.
///
/// [get] returns the open shell, or connects (concurrent callers share one
/// attempt). A closed shell, or a config whose connection fields changed
/// (address, port, user, auth, key id), is replaced on the next
/// [get].
class ConnectionPool {
  ConnectionPool(this._connect);

  /// Pool over [SshConnector]. [passwordFor] supplies passwords for
  /// password hosts that have none saved in [keyStore].
  factory ConnectionPool.ssh(
    SshConnector connector, {
    required KeyStore keyStore,
    HostKeyStore? hostKeyStore,
    FutureOr<String?> Function(HostConfig config)? passwordFor,
    Duration timeout = const Duration(seconds: 20),
  }) =>
      ConnectionPool((config) async => connector.connect(
            config,
            keyStore: keyStore,
            hostKeyStore: hostKeyStore,
            password: passwordFor == null ? null : await passwordFor(config),
            timeout: timeout,
          ));

  final ShellConnect _connect;
  final _shells = <String, _Entry>{};
  final _pending = <String, Future<RemoteShell>>{};
  bool _disposed = false;

  /// The open shell for [hostId], without connecting.
  RemoteShell? current(String hostId) {
    final e = _shells[hostId];
    return (e == null || e.shell.isClosed) ? null : e.shell;
  }

  Future<RemoteShell> get(HostConfig config) {
    if (_disposed) return Future.error(StateError('ConnectionPool disposed'));
    final key = _connKey(config);
    final e = _shells[config.id];
    if (e != null && !e.shell.isClosed && e.key == key) return Future.value(e.shell);
    final pending = _pending[config.id];
    if (pending != null) return pending;

    final f = () async {
      if (e != null) {
        _shells.remove(config.id);
        await _closeQuietly(e.shell);
      }
      final shell = await _connect(config);
      if (_disposed) {
        await _closeQuietly(shell);
        throw StateError('ConnectionPool disposed');
      }
      _shells[config.id] = _Entry(shell, key);
      return shell;
    }();
    _pending[config.id] = f;
    f.whenComplete(() => _pending.remove(config.id)).ignore();
    return f;
  }

  /// Closes and forgets the connection of [hostId] (e.g. host removed).
  Future<void> drop(String hostId) async {
    final e = _shells.remove(hostId);
    if (e != null) await _closeQuietly(e.shell);
  }

  Future<void> dispose() async {
    _disposed = true;
    final all = _shells.values.toList();
    _shells.clear();
    await Future.wait(all.map((e) => _closeQuietly(e.shell)));
  }

  static Future<void> _closeQuietly(RemoteShell s) async {
    try {
      await s.close();
    } catch (_) {}
  }

  static String _connKey(HostConfig c) => [c.host, c.port, c.user, c.auth.name, c.keyId].join('\u0000');
}

class _Entry {
  _Entry(this.shell, this.key);
  final RemoteShell shell;
  final String key;
}
