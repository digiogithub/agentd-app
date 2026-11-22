// Real repositories: transport (SSH) + agentd + mux + provision wired behind
// the contracts the UI consumes.

import '../core/contracts.dart';
import '../provision/provision.dart';
import '../transport/transport.dart';
import 'agentd_clients.dart';
import 'board_repository.dart';
import 'host_store.dart';
import 'hosts_repository.dart';
import 'mail_repository.dart';
import 'sessions_repository.dart';

export 'agentd_clients.dart';
export 'authorized_keys.dart';
export 'board_repository.dart';
export 'host_store.dart';
export 'hosts_repository.dart';
export 'mail_repository.dart';
export 'sessions_repository.dart';
export 'shell_session.dart';

/// Everything the app needs, built once at start.
class AppData {
  AppData({required this.hosts, required this.sessions, required this.mail, required this.board, required this.provision, required this.hostKeyPrompts, required this.clients});

  /// Production wiring: secure storage for keys, shared_preferences for
  /// hosts and trusted host keys, dartssh2 connections.
  factory AppData.create({HostStore? store, KeyStore? keys, HostKeyStore? hostKeys}) {
    final prompts = HostKeyPrompts();
    const provision = DefaultProvisionService();
    final hosts = SshHostsRepository.ssh(
      store: store ?? PrefsHostStore(),
      keys: keys ?? SecureKeyStore(),
      hostKeys: hostKeys ?? PrefsHostKeyStore(),
      provision: provision,
      prompts: prompts,
    );
    final clients = AgentdClients(hosts);
    return AppData(
      hosts: hosts,
      sessions: LiveSessionsRepository(hosts: hosts, clients: clients),
      mail: AgentdMailRepository(clients: clients),
      board: LiveBoardRepository(hosts: hosts, clients: clients),
      provision: provision,
      hostKeyPrompts: prompts,
      clients: clients,
    );
  }

  final HostsRepository hosts;
  final SessionsRepository sessions;
  final MailRepository mail;
  final BoardRepository board;
  final ProvisionService provision;
  final HostKeyPrompts hostKeyPrompts;
  final AgentdClients clients;
}
