// Prepare a host: detect, choose agentd + CLIs, show the commands, install
// with live progress.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

class CliChoice {
  const CliChoice(this.id, this.label, this.source);
  final String id;
  final String label;
  final String source; // how it is installed, shown when missing
}

const cliChoices = [
  CliChoice('claude', 'Claude Code', 'npm @anthropic-ai/claude-code'),
  CliChoice('codex', 'Codex', 'npm @openai/codex'),
  CliChoice('pando', 'Pando', 'release de GitHub'),
  CliChoice('opencode', 'opencode', 'npm opencode-ai'),
  CliChoice('gemini', 'Gemini CLI', 'npm @google/gemini-cli'),
];

/// One line of the install progress.
class _Progress {
  _Progress(this.step, this.message);
  final ProvisionStep step;
  final String message;
  bool done = false;
  bool skipped = false;
  String? error;
}

class ProvisionScreen extends ConsumerStatefulWidget {
  const ProvisionScreen({super.key, required this.hostId, this.preselect = const {}});
  final String hostId;
  final Set<String> preselect;

  @override
  ConsumerState<ProvisionScreen> createState() => _ProvisionScreenState();
}

class _ProvisionScreenState extends ConsumerState<ProvisionScreen> {
  RemoteShell? _shell;
  HostCapabilities? _caps;
  String? _detectError;
  bool _agentd = true;
  bool _hc = true;
  bool _mcp = true;
  late final Set<String> _clis = {...widget.preselect};
  bool _showCommands = false;
  bool _running = false;
  bool _finished = false;
  final List<_Progress> _progress = [];
  StreamSubscription<ProvisionEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _detect();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _detect() async {
    setState(() => _detectError = null);
    try {
      final shell = await ref.read(hostsRepositoryProvider).shell(widget.hostId);
      final caps = await ref.read(provisionServiceProvider).detect(shell);
      if (!mounted) return;
      setState(() {
        _shell = shell;
        _caps = caps;
        _agentd = !caps.has('agentd');
      });
    } catch (_) {
      if (mounted) setState(() => _detectError = 'No se pudo detectar el host');
    }
  }

  int get _count => _clis.length + (_agentd ? 1 : 0);

  void _install() {
    final shell = _shell;
    final caps = _caps;
    if (shell == null || caps == null || _count == 0) return;
    setState(() {
      _running = true;
      _finished = false;
      _progress.clear();
    });
    _sub = ref
        .read(provisionServiceProvider)
        .install(shell, caps, agentd: _agentd, hcListener: _agentd && _hc, mcp: _agentd && _mcp, clis: {..._clis})
        .listen(
          (e) {
            setState(() {
              final last = _progress.lastWhere(
                (p) => p.step == e.step && p.message == e.message && !p.done,
                orElse: () {
                  final p = _Progress(e.step, e.message);
                  _progress.add(p);
                  return p;
                },
              );
              last.done = e.done;
              last.skipped = e.skipped;
              last.error = e.error;
            });
          },
          onError: (Object _) => setState(() {
            _progress.add(_Progress(ProvisionStep.install, 'La instalación falló')..error = 'error');
            _running = false;
            _finished = true;
          }),
          onDone: () {
            if (!mounted) return;
            setState(() {
              _running = false;
              _finished = true;
            });
            ref.read(hostsRepositoryProvider).connect(widget.hostId).ignore();
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(hostsProvider).value ?? const <HostStatus>[];
    final host = hosts.where((h) => h.config.id == widget.hostId).firstOrNull;
    final caps = _caps;
    final subtitle = caps == null
        ? (_detectError ?? 'Detectando…')
        : ['${caps.os} ${caps.arch}'.trim(), ?caps.distro, if (caps.systemdUser) 'systemd de usuario'].join(' · ');

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            RouteHeader(title: 'Preparar ${host?.config.name ?? widget.hostId}', subtitle: subtitle),
            Expanded(
              child: caps == null
                  ? Center(
                      child: _detectError == null
                          ? const CircularProgressIndicator()
                          : AppButton(label: 'Reintentar', style: AppButtonStyle.outline, onPressed: _detect),
                    )
                  : (_running || _finished)
                  ? _progressList()
                  : _options(caps),
            ),
            if (caps != null) _footer(caps),
          ],
        ),
      ),
    );
  }

  Widget _options(HostCapabilities caps) {
    final detected = <Widget>[];
    final missing = <Widget>[];
    for (final t in ['agentd', 'zellij', 'tmux', 'node', ...cliChoices.map((c) => c.id)]) {
      final info = caps.tools[t];
      if (info?.installed ?? false) {
        detected.add(TagChip('$t${info!.version != null ? ' ${info.version}' : ''}', bg: AppColors.successBg, fg: AppColors.successText));
      } else if (const {'agentd', 'zellij', 'tmux', 'node'}.contains(t)) {
        missing.add(TagChip('sin $t', fg: AppColors.muted));
      }
    }
    final agentdInfo = caps.tools['agentd'];
    final agentdInstalled = agentdInfo?.installed ?? false;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        const SectionLabel('Detectado'),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [...detected, ...missing]),
        const SizedBox(height: 16),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          agentdInstalled ? 'agentd ${agentdInfo!.version ?? ''} instalado'.replaceAll('  ', ' ') : 'agentd',
                          style: AppFonts.inter(size: 15, weight: FontWeight.w600),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          agentdInstalled
                              ? 'Actívalo para reinstalar o actualizar desde la release'
                              : 'Binario en ~/.local/bin, servicio systemd de usuario, firma comprobada',
                          style: AppFonts.inter(size: 12.5, color: AppColors.muted, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  AppSwitch(value: _agentd, label: 'Instalar agentd', onChanged: (v) => setState(() => _agentd = v)),
                ],
              ),
              const SizedBox(height: 4),
              _check('Activar el listener herdr-core (Herdr, Alma, Whip)', _hc, _agentd ? (v) => setState(() => _hc = v) : null),
              _check('Registrar el MCP de agentd en los CLIs instalados', _mcp, _agentd ? (v) => setState(() => _mcp = v) : null),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const SectionLabel('Agentes de terminal'),
        const SizedBox(height: 8),
        for (final c in cliChoices) ...[_cliRow(c, caps.tools[c.id]), const SizedBox(height: 8)],
      ],
    );
  }

  Widget _check(String label, bool value, ValueChanged<bool>? onChanged) => Semantics(
    container: true,
    checked: value,
    enabled: onChanged != null,
    label: label,
    excludeSemantics: true,
    child: InkWell(
      onTap: onChanged == null ? null : () => onChanged(!value),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Checkbox(value: value, onChanged: onChanged == null ? null : (v) => onChanged(v ?? false)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label, style: AppFonts.inter(size: 13.5, color: onChanged == null ? AppColors.faint : AppColors.secondary)),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _cliRow(CliChoice c, ToolInfo? info) {
    final installed = info?.installed ?? false;
    final on = _clis.contains(c.id);
    final sub = installed ? '${info!.version ?? '?'} · instalado' : c.source;
    final action = installed ? (on ? 'Se actualizará' : 'Actualizar') : (on ? 'Se instalará' : 'Instalar');
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.label, style: AppFonts.inter(size: 14.5, weight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(sub, style: AppFonts.mono(size: 12, color: AppColors.muted)),
              ],
            ),
          ),
          AppButton(
            label: action,
            semanticLabel: '$action ${c.label}',
            style: on ? AppButtonStyle.soft : AppButtonStyle.outline,
            radius: 10,
            fontSize: 13,
            onPressed: () => setState(() => on ? _clis.remove(c.id) : _clis.add(c.id)),
          ),
        ],
      ),
    );
  }

  Widget _progressList() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    children: [
      SectionLabel(_running ? 'Instalando' : 'Resultado'),
      const SizedBox(height: 8),
      for (final p in _progress)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: p.error != null && !p.skipped ? AppColors.dangerBg : AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.error != null && !p.skipped ? AppColors.dangerBorder : AppColors.border),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: p.skipped
                      ? Icon(Icons.remove_circle_outline, size: 20, color: AppColors.muted)
                      : p.error != null
                      ? Icon(Icons.error_outline, size: 20, color: AppColors.danger)
                      : p.done
                      ? Icon(Icons.check_circle, size: 20, color: AppColors.success)
                      : const CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.message, style: AppFonts.inter(size: 14, weight: FontWeight.w500)),
                      if (p.skipped) Text('Omitido: falló un paso del que depende', style: AppFonts.inter(size: 12, color: AppColors.muted)),
                      if (p.error != null) Text(p.error!, style: AppFonts.mono(size: 12, color: AppColors.danger)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  Widget _footer(HostCapabilities caps) {
    final service = ref.read(provisionServiceProvider);
    final steps = service.planSteps(caps, agentd: _agentd, hcListener: _agentd && _hc, mcp: _agentd && _mcp, clis: {..._clis});
    final failed = _progress.any((p) => p.error != null || p.skipped);
    final String label;
    final VoidCallback? onPressed;
    if (_running) {
      label = 'Instalando…';
      onPressed = null;
    } else if (_finished) {
      label = failed ? 'Volver a intentar' : 'Listo';
      onPressed = failed ? _install : () => Navigator.of(context).maybePop();
    } else {
      label = _count == 0 ? 'Nada que instalar' : 'Instalar ${plural2(_count)}';
      onPressed = _count == 0 ? null : _install;
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_running && !_finished) ...[
            Semantics(
              container: true,
              button: true,
              expanded: _showCommands,
              label: 'Ver los comandos que se ejecutarán por SSH',
              excludeSemantics: true,
              child: InkWell(
                onTap: () => setState(() => _showCommands = !_showCommands),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      Icon(_showCommands ? Icons.expand_less : Icons.chevron_right, size: 16, color: AppColors.muted),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Ver los comandos que se ejecutarán por SSH',
                          style: AppFonts.inter(size: 12.5, color: AppColors.muted),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_showCommands)
              Container(
                key: const ValueKey('plan'),
                constraints: const BoxConstraints(maxHeight: 180),
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppColors.terminalBg, borderRadius: BorderRadius.circular(10)),
                child: SingleChildScrollView(
                  child: SelectableText(
                    steps.isEmpty ? '# nada que ejecutar' : [for (final st in steps) '# ${st.title}\n${st.command}'].join('\n\n'),
                    style: AppFonts.mono(size: 11, color: AppColors.secondary, height: 1.5),
                  ),
                ),
              ),
          ],
          AppButton(label: label, height: 52, radius: 14, fontSize: 15, bold: true, expand: true, onPressed: onPressed),
        ],
      ),
    );
  }
}

String plural2(int n) => n == 1 ? '1 componente' : '$n componentes';
