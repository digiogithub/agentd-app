// Bottom sheets of the Panel: answer an agent's question (option or free
// text, to its mailbox or its prompt) and pick an option of a terminal menu.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../panel_model.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/panel_widgets.dart';

/// How a Panel sheet was closed.
enum PanelSheetResult {
  /// The answer was sent.
  sent,

  /// The user asked for the agent's task view.
  openAgent,

  /// The user asked for the session (chat / terminal).
  openChat,
}

Future<PanelSheetResult?> showQuestionSheet(BuildContext context, {required BoardSession session, required AgentQuestion question}) =>
    showModalBottomSheet<PanelSheetResult>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => QuestionSheet(session: session, question: question),
    );

Future<PanelSheetResult?> showMenuSheet(BuildContext context, {required AgentSession session}) => showModalBottomSheet<PanelSheetResult>(
  context: context,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
  builder: (_) => MenuSheet(session: session),
);

/// The live session behind a board entry (null once it is gone).
AgentSession? liveSessionOf(WidgetRef ref, String key) => ref.watch(sessionsProvider).value?.where((s) => s.key == key).firstOrNull;

class _SheetHead extends StatelessWidget {
  const _SheetHead({required this.name, required this.subtitle, required this.pill});
  final String name;
  final String subtitle;
  final String pill;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: AppFonts.mono(size: 14, weight: FontWeight.w500), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(subtitle, style: AppText.caption, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
      const SizedBox(width: 8),
      StatusPill(pill, bg: AppColors.waitingBg, fg: AppColors.waiting),
    ],
  );
}

class QuestionSheet extends ConsumerStatefulWidget {
  const QuestionSheet({super.key, required this.session, required this.question});
  final BoardSession session;
  final AgentQuestion question;

  @override
  ConsumerState<QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends ConsumerState<QuestionSheet> {
  final _text = TextEditingController();
  SendTarget _target = SendTarget.mailbox;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Sends [body]: a mailbox reply, or (free text only) the agent's prompt.
  /// A prompted answer is then recorded with a quiet reply, which closes the
  /// question without typing the text a second time.
  Future<void> _send(String body, SendTarget target, AgentSession? live) async {
    if (body.isEmpty || _sending) return;
    final board = ref.read(boardRepositoryProvider);
    final s = widget.session;
    setState(() => _sending = true);
    try {
      if (target == SendTarget.prompt) {
        if (live == null) throw StateError('session gone');
        await ref.read(sessionsRepositoryProvider).prompt(live, body);
      } else {
        await board.answer(s.hostId, widget.question.id, body);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      showToast(context, target == SendTarget.prompt ? 'No se pudo escribir en el prompt' : 'No se pudo enviar la respuesta');
      return;
    }
    var note = target == SendTarget.prompt ? 'Escrito en el prompt de ${s.name}' : 'Respuesta enviada a ${s.name}';
    if (target == SendTarget.prompt) {
      try {
        await board.answer(s.hostId, widget.question.id, body, notify: false);
      } catch (_) {
        // The agent has the answer: only the record failed.
        note = 'Escrito en el prompt, pero la pregunta sigue abierta en el buzón';
      }
    }
    if (!mounted) return;
    showToast(context, note);
    Navigator.of(context).pop(PanelSheetResult.sent);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final q = widget.question;
    final live = liveSessionOf(ref, s.key);
    final hostName = ref.watch(hostNamesProvider)[s.hostId] ?? '';
    final canOperate = ref.watch(hostConfigProvider(s.hostId))?.canOperate ?? true;
    final (headline, rest) = splitQuestion(q.body);
    final task = q.taskId == null ? null : s.tasks.where((t) => t.id == q.taskId).firstOrNull;
    final subtitle = [if (hostName.isNotEmpty) hostName, statusLabel(s.status).toLowerCase(), if (q.createdAt != null) relativeTime(q.createdAt)].join(' · ');

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              const SizedBox(height: 14),
              _SheetHead(name: s.name, subtitle: subtitle, pill: 'Pregunta'),
              const SizedBox(height: 14),
              InlineCodeText(headline, style: AppFonts.inter(size: 16, weight: FontWeight.w500, height: 1.45)),
              if (rest.isNotEmpty) ...[
                const SizedBox(height: 10),
                InlineCodeText(rest, style: AppFonts.inter(size: 13, color: AppColors.secondary, height: 1.5)),
              ],
              if (task != null) ...[const SizedBox(height: 10), Text('Bloquea la tarea «${task.title}»', style: AppText.caption)],
              if (!canOperate) ...[
                const SizedBox(height: 14),
                Text('Este dispositivo solo puede mirar: no puede responder.', style: AppText.caption),
              ] else ...[
                if (q.options.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  for (final (i, o) in q.options.indexed) ...[
                    if (i > 0) const SizedBox(height: 8),
                    // An option always answers through the mailbox.
                    AppButton(
                      key: ValueKey('answer-option-$i'),
                      label: o,
                      style: i == 0 ? AppButtonStyle.waiting : AppButtonStyle.outline,
                      height: 48,
                      fontSize: 15,
                      expand: true,
                      onPressed: _sending ? null : () => _send(o, SendTarget.mailbox, live),
                    ),
                  ],
                ],
                const SizedBox(height: 14),
                Text(q.options.isEmpty ? 'Tu respuesta' : 'O responde con tus palabras', style: AppText.caption),
                const SizedBox(height: 6),
                TextField(
                  key: const ValueKey('answer-text'),
                  controller: _text,
                  minLines: 2,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  onChanged: (_) => setState(() {}),
                  style: AppFonts.inter(size: 14),
                  decoration: AppTextField.decoration(hint: 'Escribe una respuesta…').copyWith(fillColor: AppColors.bg),
                ),
                const SizedBox(height: 14),
                Text('Enviar tu texto a', style: AppText.caption),
                const SizedBox(height: 6),
                SendTargetControl(value: _target, promptEnabled: live != null, onChanged: (t) => setState(() => _target = t)),
                const SizedBox(height: 6),
                Text(
                  'Buzón: le llega como respuesta a su pregunta cuando quede libre. Prompt: se escribe ahora en su terminal y la pregunta se cierra.',
                  style: AppText.caption.copyWith(height: 1.45),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: AppButton(
                      label: 'Abrir agente',
                      style: AppButtonStyle.outline,
                      height: 48,
                      expand: true,
                      onPressed: () => Navigator.of(context).pop(PanelSheetResult.openAgent),
                    ),
                  ),
                  if (canOperate) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: AppButton(
                        key: const ValueKey('answer-send'),
                        label: _sending ? 'Enviando…' : 'Enviar',
                        height: 48,
                        fontSize: 15,
                        expand: true,
                        onPressed: _text.text.trim().isEmpty || _sending ? null : () => _send(_text.text.trim(), _target, live),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The options of a terminal menu: one tap picks (act choose with the
/// menu's revision and epoch, so a changed screen is refused).
class MenuSheet extends ConsumerStatefulWidget {
  const MenuSheet({super.key, required this.session});
  final AgentSession session;

  @override
  ConsumerState<MenuSheet> createState() => _MenuSheetState();
}

class _MenuSheetState extends ConsumerState<MenuSheet> {
  bool _sending = false;

  Future<void> _choose(AgentSession s, SessionOption o) async {
    final p = s.pending;
    final rev = p?.revision;
    final epoch = p?.epoch;
    if (rev == null || epoch == null || _sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(sessionsRepositoryProvider).choose(s, o, revision: rev, epoch: epoch);
      if (mounted) Navigator.of(context).pop(PanelSheetResult.sent);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      showToast(context, 'No se pudo responder: el menú cambió o la sesión no está lista');
    }
  }

  @override
  Widget build(BuildContext context) {
    // The live session: its menu may change while the sheet is open.
    final s = liveSessionOf(ref, widget.session.key) ?? widget.session;
    final p = s.pending;
    final hostName = ref.watch(hostNamesProvider)[s.hostId] ?? '';
    final canOperate = ref.watch(hostConfigProvider(s.hostId))?.canOperate ?? true;
    final answerable = canOperate && p != null && p.revision != null && p.epoch != null;
    final subtitle = [if (hostName.isNotEmpty) hostName, statusLabel(s.status).toLowerCase(), if (s.updatedAt != null) relativeTime(s.updatedAt)].join(' · ');

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              const SizedBox(height: 14),
              _SheetHead(name: s.name, subtitle: subtitle, pill: p == null ? 'Respondida' : pendingLabel(p)),
              const SizedBox(height: 14),
              if (p == null)
                Text('El menú ya no está en pantalla.', style: AppText.body)
              else ...[
                InlineCodeText(p.question.isEmpty ? 'Esperando una respuesta' : p.question, style: AppFonts.inter(size: 16, weight: FontWeight.w500, height: 1.45)),
                if (p.detail != null) ...[const SizedBox(height: 8), Text(p.detail!, style: AppFonts.mono(size: 12.5, color: AppColors.secondary, height: 1.5))],
                if (!answerable) ...[
                  const SizedBox(height: 14),
                  Text(canOperate ? 'Abre el chat para responder.' : 'Este dispositivo solo puede mirar: no puede responder.', style: AppText.caption),
                ] else ...[
                  const SizedBox(height: 14),
                  for (final (i, o) in p.options.indexed) ...[
                    if (i > 0) const SizedBox(height: 8),
                    AppButton(
                      key: ValueKey('menu-option-${o.id}'),
                      label: o.label,
                      style: AppButtonStyle.outline,
                      height: 48,
                      expand: true,
                      onPressed: _sending ? null : () => _choose(s, o),
                    ),
                  ],
                ],
              ],
              const SizedBox(height: 14),
              AppButton(
                label: 'Abrir chat',
                style: AppButtonStyle.outline,
                height: 48,
                expand: true,
                onPressed: () => Navigator.of(context).pop(PanelSheetResult.openChat),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
