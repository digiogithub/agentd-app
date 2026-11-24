// One agent's plan: its tasks grouped by state (agents write them, the app
// only reads), its open questions and a message box to its mailbox or prompt.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../panel_model.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/panel_widgets.dart';
import 'panel_sheets.dart';
import 'session_screen.dart';

class PanelAgentScreen extends ConsumerStatefulWidget {
  const PanelAgentScreen({super.key, required this.hostId, required this.name});
  final String hostId;
  final String name;

  @override
  ConsumerState<PanelAgentScreen> createState() => _PanelAgentScreenState();
}

class _PanelAgentScreenState extends ConsumerState<PanelAgentScreen> {
  final _text = TextEditingController();
  SendTarget _target = SendTarget.mailbox;
  bool _sending = false;

  /// Confirmation of the last message, shown above the box (a toast would
  /// cover it) until the user types again.
  String? _notice;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _openChat(AgentSession s) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SessionScreen(session: s)));

  // "Abrir agente" of the sheet lands here: this is that screen already.
  Future<void> _answer(BoardSession s, AgentQuestion q) => showQuestionSheet(context, session: s, question: q);

  Future<void> _send(AgentSession? live) async {
    final body = _text.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      if (_target == SendTarget.prompt) {
        if (live == null) throw StateError('session gone');
        await ref.read(sessionsRepositoryProvider).prompt(live, body);
      } else {
        await ref.read(mailRepositoryProvider).send(widget.hostId, to: widget.name, body: body);
      }
      if (!mounted) return;
      _text.clear();
      _notice = _target == SendTarget.prompt ? 'Escrito en el prompt' : 'Mensaje enviado al buzón';
    } catch (_) {
      if (mounted) showToast(context, _target == SendTarget.prompt ? 'No se pudo escribir en el prompt' : 'No se pudo enviar el mensaje');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = '${widget.hostId}/${SessionSource.agentd.name}/${widget.name}';
    final live = liveSessionOf(ref, key);
    final board = ref.watch(boardProvider(widget.hostId)).value;
    final s =
        board?.sessions.where((x) => x.name == widget.name).firstOrNull ??
        (live == null
            ? null
            : BoardSession(hostId: live.hostId, name: live.name, status: live.status, attention: live.attention, turn: live.turn, preview: live.preview));
    final hostName = ref.watch(hostNamesProvider)[widget.hostId] ?? '';
    final canOperate = ref.watch(hostConfigProvider(widget.hostId))?.canOperate ?? true;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            RouteHeader(
              title: widget.name,
              titleStyle: AppFonts.mono(size: 17, weight: FontWeight.w500),
              subtitle: [if (hostName.isNotEmpty) hostName, if (live?.cwd != null) shortPath(live!.cwd!)].join(' · '),
              trailing: [
                if (s != null) StatusPill.status(s.status),
                if (live != null) ...[
                  const SizedBox(width: 4),
                  RoundIconButton(icon: Icons.chat_bubble_outline, label: 'Abrir chat', iconSize: 20, onPressed: () => _openChat(live)),
                ],
              ],
            ),
            if (s == null)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('Esta sesión ya no está en el panel.', textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppColors.muted)),
                  ),
                ),
              )
            else ...[
              if (s.tasks.isNotEmpty) _progress(s),
              Divider(height: 1, color: AppColors.divider),
              Expanded(child: _body(s, canOperate)),
              if (canOperate && s.status != AgentStatus.exited) _messageBox(live),
            ],
          ],
        ),
      ),
    );
  }

  Widget _progress(BoardSession s) {
    DateTime? last;
    for (final t in s.tasks) {
      final u = t.updatedAt;
      if (u != null && (last == null || u.isAfter(last))) last = u;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
      child: Row(
        children: [
          Expanded(child: TaskProgressBar(progressOf(s), height: 5)),
          const SizedBox(width: 10),
          Text([progressLabel(s), if (last != null) relativeTime(last)].join(' · '), style: AppFonts.inter(size: 12, color: AppColors.secondary)),
        ],
      ),
    );
  }

  Widget _body(BoardSession s, bool canOperate) {
    final children = <Widget>[];
    void gap() {
      if (children.isNotEmpty) children.add(const SizedBox(height: 16));
    }

    if (s.questions.isNotEmpty) {
      children.add(SectionLabel('Te pregunta', color: AppColors.waiting));
      for (final q in s.questions) {
        children.add(const SizedBox(height: 8));
        children.add(
          AppCard(
            key: ValueKey('agent-question-${q.id}'),
            radius: 14,
            color: AppColors.questionBg,
            borderColor: AppColors.questionBorder,
            onTap: () => _answer(s, q),
            semanticLabel: 'Pregunta abierta',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InlineCodeText(splitQuestion(q.body).$1, style: AppFonts.inter(size: 14, height: 1.4), maxLines: 4),
                const SizedBox(height: 6),
                Text(
                  [if (q.createdAt != null) relativeTime(q.createdAt), canOperate ? 'toca para responder' : 'solo lectura'].join(' · '),
                  style: AppText.caption,
                ),
              ],
            ),
          ),
        );
      }
    }

    void group(String title, TaskStatus status, Color color, {bool filled = false, Color? text}) {
      final list = s.tasks.where((t) => t.status == status).toList();
      if (list.isEmpty) return;
      gap();
      children.add(SectionLabel('$title · ${list.length}', color: color));
      for (final t in list) {
        final asked = s.questions.where((q) => q.taskId == t.id).firstOrNull;
        children.add(const SizedBox(height: 8));
        children.add(
          _TaskRow(
            task: t,
            color: color,
            filled: filled,
            textColor: text ?? AppColors.text,
            struck: status == TaskStatus.cancelled,
            extra: asked == null ? null : 'Pregunta abierta: ${splitQuestion(asked.body).$1}',
          ),
        );
      }
    }

    group('En curso', TaskStatus.inProgress, AppColors.working);
    group('Bloqueadas', TaskStatus.blocked, AppColors.waiting);
    group('Pendientes', TaskStatus.pending, AppColors.muted);
    group('Hechas', TaskStatus.done, AppColors.success, filled: true, text: AppColors.muted);
    group('Canceladas', TaskStatus.cancelled, AppColors.faint, text: AppColors.faint);

    if (s.tasks.isEmpty) {
      gap();
      children.add(
        Text(
          'Este agente no ha informado de tareas.${s.preview == null ? '' : '\n\n${s.preview}'}',
          style: AppText.body.copyWith(color: AppColors.muted),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.fromLTRB(18, 14, 18, 20), children: children);
  }

  Widget _messageBox(AgentSession? live) => Container(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
    decoration: BoxDecoration(
      color: AppColors.navBg,
      border: Border(top: BorderSide(color: AppColors.divider)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_notice != null) ...[
          Semantics(liveRegion: true, child: Text(_notice!, style: AppText.caption.copyWith(color: AppColors.successText))),
          const SizedBox(height: 6),
        ],
        Row(
          children: [
            Expanded(
              child: AppTextField(
                key: const ValueKey('agent-message'),
                controller: _text,
                hint: 'Mensaje a ${widget.name}…',
                semanticLabel: 'Mensaje al agente',
                onChanged: (_) => setState(() => _notice = null),
                onSubmitted: (_) => _send(live),
              ),
            ),
            const SizedBox(width: 8),
            AppButton(
              key: const ValueKey('agent-send'),
              label: 'Enviar',
              onPressed: _text.text.trim().isEmpty || _sending ? null : () => _send(live),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('Enviar a', style: AppText.caption),
            const SizedBox(width: 10),
            Expanded(
              child: SendTargetControl(value: _target, promptEnabled: live != null, onChanged: (t) => setState(() => _target = t)),
            ),
          ],
        ),
      ],
    ),
  );
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.color, required this.filled, required this.textColor, this.struck = false, this.extra});
  final AgentTask task;
  final Color color;
  final bool filled;
  final Color textColor;
  final bool struck;
  final String? extra;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ExcludeSemantics(
        child: Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.only(top: 3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? color : null,
            border: Border.all(color: color, width: 2),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.title,
              style: AppFonts.inter(size: 14, color: textColor, height: 1.4).copyWith(decoration: struck ? TextDecoration.lineThrough : null),
            ),
            if (task.fromBacklog) ...[const SizedBox(height: 2), Text('Del backlog', style: AppFonts.inter(size: 12, color: AppColors.muted, height: 1.4))],
            for (final note in [task.note, extra])
              if (note != null && note.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(note, style: AppFonts.inter(size: 12, color: AppColors.waiting, height: 1.4)),
              ],
          ],
        ),
      ),
    ],
  );
}
