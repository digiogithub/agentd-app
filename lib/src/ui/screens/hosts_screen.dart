// Saved hosts with their state and what they have installed.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../providers.dart';
import '../push_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'devices_screen.dart' show scopeLabel;
import 'add_host_screen.dart';
import 'provision_screen.dart';

const agentClis = ['claude', 'codex', 'pando', 'opencode', 'gemini', 'grok'];

class HostsScreen extends ConsumerWidget {
  const HostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hostsAsync = ref.watch(hostsProvider);
    final hosts = hostsAsync.value ?? const <HostStatus>[];
    final sessions = ref.watch(sessionsProvider).value ?? const <AgentSession>[];
    final online = hosts.where((h) => h.state == HostState.online).toList();
    final noAgentd = online.where((h) => h.capabilities != null && !h.capabilities!.has('agentd')).length;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          ScreenHeader(
            overline: ['${online.length} en línea', if (noAgentd > 0) '$noAgentd sin agentd'].join(' · '),
            title: 'Hosts',
            trailing: RoundIconButton(
              icon: Icons.add,
              label: 'Añadir host',
              bg: AppColors.accent,
              fg: AppColors.bg,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddHostScreen())),
            ),
          ),
          Expanded(
            child: hosts.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        hostsAsync.isLoading ? 'Cargando…' : 'Añade un host por SSH para ver sus agentes.',
                        textAlign: TextAlign.center,
                        style: AppText.body.copyWith(color: AppColors.muted),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: hosts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => HostCard(host: hosts[i], sessions: sessions.where((s) => s.hostId == hosts[i].config.id).toList()),
                  ),
          ),
        ],
      ),
    );
  }
}

class HostCard extends ConsumerWidget {
  const HostCard({super.key, required this.host, required this.sessions});
  final HostStatus host;
  final List<AgentSession> sessions;

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final push = PushScope.maybeOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Quitar ${host.config.name}?', style: AppFonts.inter(size: 18, weight: FontWeight.w600)),
        content: Text(
          host.config.isRelay
              ? 'Se borra de la app junto con la clave de este dispositivo. En el host sigue emparejado hasta que lo revoques: Ajustes > Dispositivos, o agentd relay revoke en el host.'
              : 'Se borra de la app; el host no se toca.',
          style: AppText.body,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Quitar', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    // The host stops pushing to this device before it is forgotten.
    await push?.forget(host.config.id);
    await ref.read(hostsRepositoryProvider).remove(host.config.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = host.config;
    final caps = host.capabilities;
    final online = host.state == HostState.online;
    final relay = c.relay;
    final address = c.isRelay ? 'relay · ${c.host}' : '${c.user}@${c.host}${c.port != 22 ? ':${c.port}' : ''} · SSH';

    if (!online) {
      final (sub, color) = switch (host.state) {
        HostState.connecting => ('Conectando…', AppColors.muted),
        HostState.error => (host.error ?? 'Error de conexión', AppColors.danger),
        _ => (host.error ?? 'Sin conexión', AppColors.muted),
      };
      final offlineSub = c.isRelay ? '$sub · relay' : sub;
      return GestureDetector(
        onLongPress: () => _remove(context, ref),
        child: AppCard(
          semanticLabel: '${c.name}, $offlineSub',
          child: Row(
            children: [
              Semantics(
                label: 'Sin conexión',
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.faint, width: 2),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.name,
                      style: AppFonts.inter(size: 16, weight: FontWeight.w600, color: AppColors.secondary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      offlineSub,
                      style: AppFonts.inter(size: 12, color: color),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (host.state != HostState.connecting)
                AppButton(
                  label: 'Reintentar',
                  style: AppButtonStyle.outline,
                  radius: 18,
                  fontSize: 13,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  // The error state shows the failure; nothing to report here.
                  onPressed: () => ref.read(hostsRepositoryProvider).connect(c.id).ignore(),
                ),
            ],
          ),
        ),
      );
    }

    final hasAgentd = caps?.has('agentd') ?? false;
    final agentdSessions = sessions.where((s) => s.source == SessionSource.agentd).length;
    final muxSessions = sessions.where((s) => s.source != SessionSource.agentd).toList();
    final count = hasAgentd
        ? plural(host.sessionCount > 0 ? host.sessionCount : agentdSessions, 'sesión', 'sesiones')
        : muxSessions.isNotEmpty
        ? '${muxSessions.length} ${muxSessions.first.source.name}'
        : 'sin sesiones';
    final clis = agentClis.where((t) => caps?.has(t) ?? false).toList();

    final tags = <Widget>[
      if (relay != null) ...[
        TagChip('relay', bg: AppColors.accentBg, fg: AppColors.accentLight),
        TagChip(scopeLabel(relay.scope)),
        if (relay.sessions.isNotEmpty) TagChip('solo ${relay.sessions.join(', ')}'),
      ] else if (hasAgentd)
        TagChip('agentd ${caps!.tools['agentd']?.version ?? ''}'.trim(), bg: AppColors.accentBg, fg: AppColors.accentLight),
      if (hasAgentd) ...[
        if (caps!.has('zellij')) const TagChip('zellij'),
        if (caps.has('tmux')) const TagChip('tmux'),
      ] else
        for (final s in muxSessions) TagChip('${s.source.name} · ${s.name}'),
      if (clis.isNotEmpty) TagChip(clis.join(' · ')),
    ];

    return GestureDetector(
      onLongPress: () => _remove(context, ref),
      child: AppCard(
        semanticLabel: '${c.name}, en línea, $count',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Semantics(
                  label: 'En línea',
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: AppColors.success, shape: BoxShape.circle),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name, style: AppFonts.inter(size: 16, weight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        address,
                        style: AppFonts.mono(size: 12, color: AppColors.muted),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Text(count, style: AppFonts.inter(size: 13, color: AppColors.secondary)),
              ],
            ),
            if (tags.isNotEmpty) ...[const SizedBox(height: 12), Wrap(spacing: 6, runSpacing: 6, children: tags)],
            if (!hasAgentd) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Sin agentd solo hay terminal. Instálalo por SSH para tener chat, aprobaciones y buzón entre agentes.',
                      style: AppFonts.inter(size: 13.5, color: AppColors.secondary, height: 1.45),
                    ),
                    const SizedBox(height: 10),
                    AppButton(
                      label: 'Instalar agentd en ${c.name}',
                      style: AppButtonStyle.light,
                      expand: true,
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProvisionScreen(hostId: c.id))),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

