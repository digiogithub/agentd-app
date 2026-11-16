// New session: host, where it runs, project, agent, first message.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'provision_screen.dart';
import 'session_screen.dart';

enum LaunchTarget { agentd, zellij, tmux, shell }

class AgentChoice {
  const AgentChoice(this.id, this.label);
  final String id; // harness / tool name
  final String label;
}

const agentChoices = [
  AgentChoice('claude', 'Claude Code'),
  AgentChoice('codex', 'Codex'),
  AgentChoice('pando', 'Pando'),
  AgentChoice('opencode', 'opencode'),
  AgentChoice('gemini', 'Gemini CLI'),
  AgentChoice('bash', 'Shell'),
];

const _targetHints = {
  LaunchTarget.agentd: 'Recomendado: vista chat, aprobaciones con revisión, buzón entre agentes y estado fiable.',
  LaunchTarget.zellij: 'Pane nuevo en la sesión zellij del host. Terminal completa; el chat se deduce de la pantalla.',
  LaunchTarget.tmux: 'Ventana nueva en tmux. Terminal completa; el chat se deduce de la pantalla.',
  LaunchTarget.shell: 'Shell de login por SSH sin multiplexor: solo terminal, se pierde al desconectar o al cerrar la app.',
};

class NewSessionScreen extends ConsumerStatefulWidget {
  const NewSessionScreen({super.key, this.hostId});
  final String? hostId;

  @override
  ConsumerState<NewSessionScreen> createState() => _NewSessionScreenState();
}

class _NewSessionScreenState extends ConsumerState<NewSessionScreen> {
  String? _hostId;
  LaunchTarget _target = LaunchTarget.agentd;
  String? _project;
  String _agent = 'claude';
  final List<String> _extraProjects = [];
  final _prompt = TextEditingController();
  bool _launching = false;

  @override
  void initState() {
    super.initState();
    _hostId = widget.hostId;
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  HostStatus? _host(List<HostStatus> hosts) {
    final online = hosts.where((h) => h.state == HostState.online).toList();
    final byId = hosts.where((h) => h.config.id == _hostId).firstOrNull;
    return byId ?? online.where((h) => h.capabilities?.has('agentd') ?? false).firstOrNull ?? online.firstOrNull ?? hosts.firstOrNull;
  }

  bool _targetAvailable(HostStatus? h, LaunchTarget t) {
    final caps = h?.capabilities;
    if (caps == null) return t == LaunchTarget.shell;
    return switch (t) {
      LaunchTarget.agentd => caps.has('agentd'),
      LaunchTarget.zellij => caps.has('zellij'),
      LaunchTarget.tmux => caps.has('tmux'),
      LaunchTarget.shell => true,
    };
  }

  String _name(String project, LaunchTarget target) =>
      target == LaunchTarget.agentd ? '$_agent@$project' : '${target == LaunchTarget.shell ? 'ssh' : target.name} · $_agent en $project';

  Future<void> _pickHost(List<HostStatus> hosts) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final h in hosts)
              ListTile(
                enabled: h.state == HostState.online,
                leading: _Dot(online: h.state == HostState.online),
                title: Text(h.config.name, style: AppFonts.inter(size: 15, weight: FontWeight.w600)),
                subtitle: Text(_hostSub(h), style: AppText.caption),
                onTap: () => Navigator.pop(ctx, h.config.id),
              ),
          ],
        ),
      ),
    );
    if (id != null) setState(() => _hostId = id);
  }

  Future<void> _addFolder() async {
    final c = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Carpeta o alias', style: AppFonts.inter(size: 18, weight: FontWeight.w600)),
        content: AppTextField(controller: c, hint: '~/src/proyecto', mono: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Añadir')),
        ],
      ),
    );
    c.dispose();
    final p = v?.trim() ?? '';
    if (p.isEmpty) return;
    setState(() {
      if (!_extraProjects.contains(p)) _extraProjects.add(p);
      _project = p;
    });
  }

  Future<void> _launch(HostStatus host, String project, LaunchTarget target) async {
    setState(() => _launching = true);
    try {
      final s = await ref
          .read(sessionsRepositoryProvider)
          .launch(
            hostId: host.config.id,
            where: SessionSource.values.byName(target.name),
            project: project,
            harness: _agent,
            firstPrompt: _prompt.text.trim().isEmpty ? null : _prompt.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => SessionScreen(session: s)));
    } catch (_) {
      if (mounted) showToast(context, 'No se pudo lanzar la sesión');
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(hostsProvider).value ?? const <HostStatus>[];
    final sessions = ref.watch(sessionsProvider).value ?? const <AgentSession>[];
    final host = _host(hosts);
    final caps = host?.capabilities;
    final target = _targetAvailable(host, _target) ? _target : LaunchTarget.values.firstWhere((t) => _targetAvailable(host, t));

    // agentd aliases first; without agentd (or aliases) the projects of the
    // host's sessions.
    final aliases = host == null ? const <String>[] : (ref.watch(projectsProvider(host.config.id)).value ?? const <String>[]);
    final projects = <String>[...aliases];
    if (projects.isEmpty) {
      for (final s in sessions.where((s) => host == null || s.hostId == host.config.id)) {
        final p = s.project;
        if (p != null && p.isNotEmpty && !projects.contains(p)) projects.add(p);
      }
    }
    projects.addAll(_extraProjects.where((p) => !projects.contains(p)));
    final project = _project ?? projects.firstOrNull;
    final installed = _agent == 'bash' || (caps?.has(_agent) ?? false);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const RouteHeader(title: 'Nueva sesión', close: true),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                children: [
                  const SectionLabel('Host'),
                  const SizedBox(height: 8),
                  Semantics(
                    container: true,
                    button: true,
                    label: 'Host: ${host?.config.name ?? 'ninguno'}',
                    excludeSemantics: true,
                    child: Material(
                      color: AppColors.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: AppColors.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: hosts.isEmpty ? null : () => _pickHost(hosts),
                        child: SizedBox(
                          height: 52,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            child: Row(
                              children: [
                                _Dot(online: host?.state == HostState.online),
                                const SizedBox(width: 10),
                                Text(host?.config.name ?? 'Sin hosts', style: AppFonts.inter(size: 15, weight: FontWeight.w600)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(host == null ? '' : _hostSub(host), style: AppText.caption, overflow: TextOverflow.ellipsis),
                                ),
                                Icon(Icons.expand_more, size: 18, color: AppColors.muted),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const SectionLabel('Dónde corre'),
                  const SizedBox(height: 8),
                  SegmentedControl<LaunchTarget>(
                    radio: true,
                    options: const [(LaunchTarget.agentd, 'agentd'), (LaunchTarget.zellij, 'zellij'), (LaunchTarget.tmux, 'tmux'), (LaunchTarget.shell, 'SSH')],
                    value: target,
                    enabled: (t) => _targetAvailable(host, t),
                    onChanged: (t) => setState(() => _target = t),
                  ),
                  const SizedBox(height: 8),
                  Text(_targetHints[target]!, style: AppFonts.inter(size: 12, color: AppColors.muted, height: 1.4)),
                  const SizedBox(height: 18),
                  const SectionLabel('Proyecto'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 0,
                    children: [
                      for (final p in projects)
                        FilterPill(label: p, selected: p == project, mono: true, height: 38, radius: 10, onTap: () => setState(() => _project = p)),
                      Semantics(
                        container: true,
                        button: true,
                        label: 'Añadir carpeta',
                        excludeSemantics: true,
                        child: GestureDetector(
                          onTap: _addFolder,
                          behavior: HitTestBehavior.opaque,
                          child: SizedBox(
                            height: 44,
                            child: Center(
                              widthFactor: 1,
                              child: Container(
                                height: 38,
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Center(
                                  widthFactor: 1,
                                  child: Text('+ Carpeta…', style: AppFonts.inter(size: 13, color: AppColors.muted)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const SectionLabel('Agente'),
                  const SizedBox(height: 8),
                  for (var i = 0; i < agentChoices.length; i += 2) ...[
                    if (i > 0) const SizedBox(height: 8),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _agentTile(agentChoices[i], caps, host)),
                          const SizedBox(width: 8),
                          Expanded(child: i + 1 < agentChoices.length ? _agentTile(agentChoices[i + 1], caps, host) : const SizedBox.shrink()),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Text('PRIMER MENSAJE (OPCIONAL)', style: AppText.sectionLabel),
                  const SizedBox(height: 6),
                  AppTextField(controller: _prompt, hint: 'Qué debe hacer el agente', semanticLabel: 'Primer mensaje'),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (project != null)
                    Text.rich(
                      TextSpan(
                        style: AppFonts.inter(size: 12.5, color: AppColors.muted),
                        children: [
                          const TextSpan(text: 'Se creará '),
                          TextSpan(
                            text: _name(project, target),
                            style: AppFonts.mono(size: 12.5, color: AppColors.accentLight),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  AppButton(
                    label: _launching ? 'Lanzando…' : 'Lanzar',
                    height: 52,
                    radius: 14,
                    fontSize: 15,
                    bold: true,
                    expand: true,
                    onPressed: host == null || project == null || !installed || _launching ? null : () => _launch(host, project, target),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _agentTile(AgentChoice a, HostCapabilities? caps, HostStatus? host) {
    final tool = caps?.tools[a.id];
    final isShell = a.id == 'bash';
    final missing = !isShell && !(tool?.installed ?? false);
    final sub = isShell ? 'bash' : (missing ? 'Instalar…' : 'instalado${tool?.version != null ? ' · ${tool!.version}' : ''}');
    return SelectTile(
      selected: _agent == a.id,
      radio: true,
      semanticLabel: '${a.label}, $sub',
      onTap: () {
        if (missing && host != null) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ProvisionScreen(hostId: host.config.id, preselect: {a.id}),
            ),
          );
          return;
        }
        setState(() => _agent = a.id);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            a.label,
            style: AppFonts.inter(size: 14, weight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            style: AppFonts.inter(size: 12, color: missing ? AppColors.waiting : AppColors.muted),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

String _hostSub(HostStatus h) {
  final v = h.capabilities?.tools['agentd'];
  if (h.state != HostState.online) return 'Sin conexión';
  return (v?.installed ?? false) ? 'agentd ${v!.version ?? ''} · SSH'.replaceAll('  ', ' ') : 'SSH · sin agentd';
}

class _Dot extends StatelessWidget {
  const _Dot({required this.online});
  final bool online;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: online ? AppColors.success : Colors.transparent,
      shape: BoxShape.circle,
      border: online ? null : Border.all(color: AppColors.faint, width: 1.5),
    ),
  );
}
