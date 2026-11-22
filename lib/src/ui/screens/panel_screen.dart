// Panel: across every host, what waits for the human (agent questions,
// terminal menus, blocked tasks) and what each agent is doing. Answers go
// out from here, without opening the session.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../panel_model.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/panel_widgets.dart';
import 'panel_agent_screen.dart';
import 'panel_sheets.dart';
import 'session_screen.dart';

class PanelScreen extends ConsumerStatefulWidget {
  const PanelScreen({super.key});

  /// Waiting items shown before the "N más" row.
  static const waitingShown = 2;

  @override
  ConsumerState<PanelScreen> createState() => _PanelScreenState();
}

class _PanelScreenState extends ConsumerState<PanelScreen> {
  String? _host;
  bool _allWaiting = false;
  final Set<String> _busy = {};

  void _openAgent(String hostId, String name) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PanelAgentScreen(hostId: hostId, name: name)));

  void _openChat(AgentSession s) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SessionScreen(session: s)));

  Future<void> _answerQuestion(QuestionWaiting w) async {
    final r = await showQuestionSheet(context, session: w.session, question: w.question);
    if (r == PanelSheetResult.openAgent && mounted) _openAgent(w.hostId, w.name);
  }

  Future<void> _answerMenu(MenuWaiting w) async {
    final r = await showMenuSheet(context, session: w.session);
    if (r == PanelSheetResult.openChat && mounted) _openChat(w.session);
  }

  Future<void> _choose(AgentSession s, SessionOption? option) async {
    final p = s.pending;
    final rev = p?.revision;
    final epoch = p?.epoch;
    if (option == null || rev == null || epoch == null) {
      showToast(context, 'Sin revisión del menú: abre la sesión para responder');
      return;
    }
    setState(() => _busy.add(s.key));
    try {
      await ref.read(sessionsRepositoryProvider).choose(s, option, revision: rev, epoch: epoch);
    } catch (_) {
      if (mounted) showToast(context, 'No se pudo responder: el menú cambió o la sesión no está lista');
    } finally {
      if (mounted) setState(() => _busy.remove(s.key));
    }
  }

  Future<void> _pickHost(List<HostStatus> hosts) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              const SizedBox(height: 14),
              for (final (id, label) in [('', 'Todos los hosts'), for (final h in hosts) (h.config.id, h.config.name)]) ...[
                SelectTile(
                  selected: (_host ?? '') == id,
                  radio: true,
                  minHeight: 48,
                  onTap: () => Navigator.of(ctx).pop(id),
                  child: Align(alignment: Alignment.centerLeft, child: Text(label, style: AppFonts.inter(size: 14.5))),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _host = picked.isEmpty ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(hostsProvider).value ?? const <HostStatus>[];
    final online = [for (final h in hosts) if (h.state == HostState.online) h];
    final names = ref.watch(hostNamesProvider);
    final sessions = ref.watch(sessionsProvider).value ?? const <AgentSession>[];
    final boards = <HostBoard>[];
    var loading = false;
    for (final h in online) {
      final b = ref.watch(boardProvider(h.config.id));
      if (b.value != null) {
        boards.add(b.value!);
      } else if (b.isLoading) {
        loading = true;
      }
    }
    // A filtered host that went away shows everything again.
    final host = online.any((h) => h.config.id == _host) ? _host : null;
    final data = buildPanel(boards: boards, sessions: sessions, hostId: host);
    final several = online.length > 1 && host == null;
    String hostOf(String id) => several ? (names[id] ?? '') : '';

    final children = <Widget>[];
    if (data.waiting.isNotEmpty) {
      children.add(const SectionLabel('Te esperan', padding: EdgeInsets.fromLTRB(2, 4, 2, 0)));
      final shown = _allWaiting ? data.waiting : data.waiting.take(PanelScreen.waitingShown).toList();
      for (final w in shown) {
        children.add(const SizedBox(height: 10));
        children.add(_waitingCard(w, hostOf(w.hostId)));
      }
      final rest = data.waiting.skip(shown.length).toList();
      if (rest.isNotEmpty) {
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('panel-more'),
              onPressed: () => setState(() => _allWaiting = true),
              style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: 2)),
              child: Text(_moreLabel(rest), style: AppFonts.inter(size: 13, color: AppColors.accentLight)),
            ),
          ),
        );
      } else {
        children.add(const SizedBox(height: 14));
      }
    }
    if (data.agents.isNotEmpty) {
      children.add(const SectionLabel('Agentes', padding: EdgeInsets.fromLTRB(2, 4, 2, 0)));
      for (final a in data.agents) {
        children.add(const SizedBox(height: 10));
        children.add(_AgentCard(key: ValueKey('panel-agent-${a.key}'), session: a, hostName: hostOf(a.hostId), onTap: () => _openAgent(a.hostId, a.name)));
      }
    }

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          ScreenHeader(
            title: 'Panel',
            trailing: hosts.isEmpty
                ? null
                : AppButton(
                    key: const ValueKey('panel-host'),
                    label: host == null ? 'Todos los hosts' : (names[host] ?? host),
                    style: AppButtonStyle.outline,
                    radius: 10,
                    fontSize: 13,
                    onPressed: () => _pickHost(online),
                  ),
            bottom: Row(
              children: [
                Expanded(
                  child: _Counter(value: data.waiting.length, label: 'Te esperan', color: AppColors.waiting, bg: AppColors.waitingBg, border: AppColors.waitingBorder),
                ),
                const SizedBox(width: 8),
                Expanded(child: _Counter(value: data.inProgress, label: 'En curso', color: AppColors.working)),
                const SizedBox(width: 8),
                Expanded(child: _Counter(value: data.pending, label: 'Pendientes')),
              ],
            ),
          ),
          Expanded(
            child: children.isEmpty
                ? (loading
                      ? const Center(child: CircularProgressIndicator())
                      : Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              online.isEmpty ? 'Ningún host conectado.' : 'No hay agentes en marcha. Lanza uno desde «Agentes».',
                              textAlign: TextAlign.center,
                              style: AppText.body.copyWith(color: AppColors.muted),
                            ),
                          ),
                        ))
                : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: children),
          ),
        ],
      ),
    );
  }

  static String _what(WaitingItem w) => switch (w) {
    QuestionWaiting() => 'pregunta',
    MenuWaiting(:final pending) => pendingLabel(pending).toLowerCase(),
    BlockedWaiting() => 'tarea bloqueada',
  };

  static String _moreLabel(List<WaitingItem> rest) =>
      rest.length == 1 ? '1 más: ${_what(rest.first)} en ${rest.first.name}' : '${rest.length} más';

  Widget _waitingCard(WaitingItem w, String hostName) {
    final canOperate = ref.watch(hostConfigProvider(w.hostId))?.canOperate ?? true;
    switch (w) {
      case QuestionWaiting(:final question):
        return _WaitingCard(
          key: ValueKey('panel-question-${w.hostId}-${question.id}'),
          name: w.name,
          hostName: hostName,
          kind: 'Pregunta',
          since: w.since,
          text: splitQuestion(question.body).$1,
          actions: [
            AppButton(
              label: canOperate ? 'Responder' : 'Ver',
              style: canOperate ? AppButtonStyle.waiting : AppButtonStyle.outline,
              expand: true,
              onPressed: () => _answerQuestion(w),
            ),
          ],
        );
      case MenuWaiting(:final session, :final pending):
        final busy = _busy.contains(session.key);
        final permission = isPermission(pending) && canOperate;
        return _WaitingCard(
          key: ValueKey('panel-menu-${session.key}'),
          name: w.name,
          hostName: hostName,
          kind: pendingLabel(pending),
          since: w.since,
          text: permission && pending.detail != null ? '¿Ejecutar `${pending.detail}`?' : (pending.question.isEmpty ? 'Esperando una respuesta' : pending.question),
          actions: permission
              ? [
                  Row(
                    children: [
                      Expanded(
                        child: AppButton(
                          label: 'Sí',
                          style: AppButtonStyle.outline,
                          expand: true,
                          semanticLabel: 'Sí, permitir a ${w.name}',
                          onPressed: busy ? null : () => _choose(session, allowOption(pending)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: AppButton(
                          label: 'No',
                          style: AppButtonStyle.outline,
                          expand: true,
                          semanticLabel: 'No, denegar a ${w.name}',
                          onPressed: busy ? null : () => _choose(session, denyOption(pending)),
                        ),
                      ),
                    ],
                  ),
                ]
              : [
                  AppButton(
                    label: canOperate && pending.options.isNotEmpty ? 'Responder' : 'Ver',
                    style: canOperate ? AppButtonStyle.waiting : AppButtonStyle.outline,
                    expand: true,
                    onPressed: () => _answerMenu(w),
                  ),
                ],
        );
      case BlockedWaiting(:final task):
        return _WaitingCard(
          key: ValueKey('panel-blocked-${w.session.key}-${task.id}'),
          name: w.name,
          hostName: hostName,
          kind: 'Bloqueada',
          since: w.since,
          text: task.title,
          note: task.note,
          actions: [AppButton(label: 'Abrir agente', style: AppButtonStyle.outline, expand: true, onPressed: () => _openAgent(w.hostId, w.name))],
        );
    }
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.value, required this.label, this.color, this.bg, this.border});
  final int value;
  final String label;
  final Color? color;
  final Color? bg;
  final Color? border;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label: $value',
    excludeSemantics: true,
    child: Container(
      key: ValueKey('panel-counter-$label'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg ?? AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border ?? AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value', style: AppFonts.inter(size: 22, weight: FontWeight.w700, color: color ?? AppColors.text)),
          Text(label, style: AppFonts.inter(size: 12, color: AppColors.secondary), overflow: TextOverflow.ellipsis),
        ],
      ),
    ),
  );
}

class _WaitingCard extends StatelessWidget {
  const _WaitingCard({super.key, required this.name, required this.hostName, required this.kind, required this.since, required this.text, this.note, required this.actions});
  final String name;
  final String hostName;
  final String kind;
  final DateTime? since;
  final String text;
  final String? note;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => AppCard(
    radius: 14,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    color: AppColors.questionBg,
    borderColor: AppColors.waitingBorder,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: name, style: AppFonts.mono(size: 13, weight: FontWeight.w500)),
                    if (hostName.isNotEmpty) TextSpan(text: '  $hostName', style: AppFonts.inter(size: 12, color: AppColors.muted)),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              [kind, if (since != null) shortDuration(since)].join(' · '),
              style: AppFonts.inter(size: 12, weight: FontWeight.w600, color: AppColors.waiting),
            ),
          ],
        ),
        const SizedBox(height: 8),
        InlineCodeText(text, style: AppFonts.inter(size: 14, height: 1.4), maxLines: 4, codeSize: 13),
        if (note != null && note!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(note!, style: AppFonts.inter(size: 12, color: AppColors.waiting, height: 1.4), maxLines: 3, overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: 8),
        ...actions,
      ],
    ),
  );
}

/// One agent: name, progress of its plan and what it is on. Without tasks:
/// its status and last line.
class _AgentCard extends StatelessWidget {
  const _AgentCard({super.key, required this.session, required this.hostName, required this.onTap});
  final BoardSession session;
  final String hostName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final hasTasks = s.total > 0;
    final current = s.current?.title ?? s.tasks.where((t) => t.status == TaskStatus.blocked).firstOrNull?.title;
    final line = hasTasks ? (current ?? (s.done >= s.total ? 'Plan terminado' : s.preview ?? 'Sin tarea en curso')) : (s.preview ?? 'Sin tareas informadas');
    return AppCard(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      onTap: onTap,
      semanticLabel: hasTasks ? '${s.name}: ${s.done} de ${s.total} tareas' : '${s.name}: ${statusLabel(s.status)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: s.name, style: AppFonts.mono(size: 13, weight: FontWeight.w500)),
                      if (hostName.isNotEmpty) TextSpan(text: '  $hostName', style: AppFonts.inter(size: 12, color: AppColors.muted)),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                hasTasks ? progressLabel(s) : statusLabel(s.status),
                style: AppFonts.inter(size: 12, color: hasTasks ? AppColors.secondary : StatusColors.of(s.status).fg),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(line, style: AppFonts.inter(size: 13.5, height: 1.35, color: hasTasks ? AppColors.text : AppColors.secondary), maxLines: 2, overflow: TextOverflow.ellipsis),
          if (hasTasks) ...[const SizedBox(height: 8), TaskProgressBar(progressOf(s))],
        ],
      ),
    );
  }
}
