// Chat view of an agentd session: transcript, pending question, composer.

import 'dart:async';

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../../agentd/errors.dart';
import '../chat/chat_table_view.dart';
import '../chat/linkified_text.dart';
import '../chat/markup_text.dart';
import '../chat/table_parser.dart';
import '../format.dart';
import '../widgets/attachments/attachment.dart';
import '../widgets/attachments/attachment_source.dart';
import '../widgets/attachments/attachment_strip.dart';
import 'image_editor_screen.dart';

import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/dictation/dictation_button.dart';
import '../widgets/option_button.dart';

class ChatTab extends ConsumerStatefulWidget {
  const ChatTab({super.key, required this.session, required this.view, this.error, required this.composerFocus, required this.onOpenMailbox});
  final AgentSession session;
  final SessionView? view;
  final Object? error;
  final FocusNode composerFocus;
  final VoidCallback onOpenMailbox;

  @override
  ConsumerState<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends ConsumerState<ChatTab> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _attachments = AttachmentsController();
  bool _sending = false;
  String? _progress;
  // True while the list is pinned to its newest line; scrolling up releases
  // it and coming back to the bottom (or the button) pins it again.
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atEnd = _scroll.position.maxScrollExtent - _scroll.position.pixels <= 24;
    // Only a finger or wheel releases the follow; layout growth never does.
    final byUser = _scroll.position.userScrollDirection != ScrollDirection.idle;
    if (atEnd && !_follow) {
      setState(() => _follow = true);
    } else if (!atEnd && _follow && byUser) {
      setState(() => _follow = false);
    }
  }

  void _jumpToEnd() {
    setState(() => _follow = true);
    _pinToEnd();
  }

  void _pinToEnd({int again = 1}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      // Lazy children change the extent once laid out: settle once more.
      if (again > 0 && _follow) _pinToEnd(again: again - 1);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _attachments.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final atts = _attachments.items;
    if ((text.isEmpty && atts.isEmpty) || _sending) return;
    final repo = ref.read(sessionsRepositoryProvider);
    setState(() => _sending = true);
    var uploading = true;
    try {
      final paths = <String>[];
      for (final (i, a) in atts.indexed) {
        if (mounted) {
          setState(
            () => _progress = 'Subiendo imagen ${i + 1} de ${atts.length}',
          );
        }
        a.remotePath ??= await repo.uploadImage(
          widget.session,
          a.sendBytes,
          extension: a.sendExtension,
        );
        paths.add(a.remotePath!);
      }
      uploading = false;
      await repo.prompt(widget.session, composePrompt(text, paths));
      _follow = true;
      _input.clear();
      _attachments.clear();
    } catch (e) {
      if (mounted) {
        showToast(
          context,
          uploading ? 'No se pudieron subir las imágenes: ${errorReason(e)}' : sendErrorMessage(e),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _pickSource() async {
    if (_attachments.remaining <= 0) {
      showToast(context, 'Máximo $kMaxAttachments imágenes por mensaje');
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('attach-gallery'),
              leading: Icon(
                Icons.photo_library_outlined,
                color: AppColors.secondary,
              ),
              title: Text('Galería', style: AppFonts.inter(size: 15)),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              key: const ValueKey('attach-camera'),
              leading: Icon(
                Icons.photo_camera_outlined,
                color: AppColors.secondary,
              ),
              title: Text('Cámara', style: AppFonts.inter(size: 15)),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final source = ref.read(attachmentSourceProvider);
    try {
      final picked = choice == 'gallery'
          ? await source.gallery(limit: _attachments.remaining)
          : [?await source.camera()];
      if (!mounted || picked.isEmpty) return;
      final added = _attachments.addAll(picked);
      if (added < picked.length) {
        showToast(context, 'Máximo $kMaxAttachments imágenes por mensaje');
      }
    } catch (_) {
      if (mounted) {
        showToast(
          context,
          choice == 'gallery'
              ? 'No se pudo abrir la galería'
              : 'No se pudo abrir la cámara',
        );
      }
    }
  }

  Future<void> _editAttachment(Attachment a) async {
    final r = await openImageEditor(context, a.original, model: a.model);
    if (r == null || !mounted) return;
    _attachments.setEdit(a.id, r.model, r.png);
  }

  Future<void> _choose(SessionOption o) async {
    final p = widget.session.pending;
    final rev = p?.revision ?? widget.view?.revision;
    final epoch = p?.epoch ?? widget.view?.epoch;
    if (rev == null || epoch == null) {
      showToast(context, 'Sin revisión del menú: espera a que se actualice la vista');
      return;
    }
    try {
      await ref.read(sessionsRepositoryProvider).choose(widget.session, o, revision: rev, epoch: epoch);
    } catch (_) {
      if (mounted) showToast(context, 'El menú cambió: revisa la pregunta actualizada');
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final items = view?.items ?? const <ChatItem>[];
    final pending = widget.session.pending;
    final host = ref.watch(hostConfigProvider(widget.session.hostId));
    final canOperate = host?.canOperate ?? true;
    final inbox = ref.watch(inboxProvider(widget.session.hostId)).value ?? const <MailMessage>[];
    final queued = inbox.where((m) => m.to == widget.session.name && m.state == MailState.queued).length;
    if (_follow) _pinToEnd();

    final children = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) {
        final tight = items[i].role == ChatRole.tool && items[i - 1].role != ChatRole.user;
        children.add(SizedBox(height: tight ? 8 : 14));
      }
      children.add(ChatItemView(item: items[i]));
    }
    if (pending != null) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 14));
      final card = PendingCard(
        key: ValueKey('pending-${pending.revision}-${pending.question}'),
        pending: pending,
        onAnswer: _choose,
        onWriteOther: () => widget.composerFocus.requestFocus(),
      );
      // A view-only relay device sees the question but cannot answer it.
      // The question card is answered, not selected.
      children.add(SelectionContainer.disabled(child: canOperate ? card : IgnorePointer(child: Opacity(opacity: 0.55, child: card))));
    }

    return Column(
      children: [
        Expanded(
          child: view == null && widget.error == null
              ? const Center(child: CircularProgressIndicator())
              : widget.error != null && view == null
              ? Center(
                  child: Text('No se pudo cargar la vista', style: AppText.body.copyWith(color: AppColors.danger)),
                )
              : Stack(
                  children: [
                    // Long-press selects chat text; the handles extend the
                    // selection across paragraphs and entries, Copy copies it.
                    SelectionArea(
                      child: ListView(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), children: children),
                    ),
                    if (!_follow)
                      Positioned(
                        right: 16,
                        bottom: 12,
                        child: RoundIconButton(
                          icon: Icons.arrow_downward,
                          label: 'Ir al final',
                          bg: AppColors.surface,
                          border: AppColors.border,
                          fg: AppColors.secondary,
                          iconSize: 20,
                          onPressed: _jumpToEnd,
                        ),
                      ),
                  ],
                ),
        ),
        if (!canOperate)
          Container(
            key: const ValueKey('read-only-note'),
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.divider)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Row(
              children: [
                Icon(Icons.visibility_outlined, size: 16, color: AppColors.muted),
                const SizedBox(width: 8),
                Expanded(child: Text('Solo lectura: este dispositivo puede ver, no escribir ni aprobar', style: AppText.caption)),
              ],
            ),
          )
        else
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.divider)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (queued > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 0, 8),
                  child: Row(
                    children: [
                      Icon(Icons.schedule, size: 14, color: AppColors.muted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${queued == 1 ? '1 mensaje en cola' : '$queued mensajes en cola'}: se entrega cuando el agente quede libre',
                          style: AppText.caption,
                        ),
                      ),
                      Semantics(
                        container: true,
                        button: true,
                        label: 'Ver mensajes en cola',
                        excludeSemantics: true,
                        child: InkWell(
                          onTap: widget.onOpenMailbox,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                            child: Center(
                              child: Text('Ver', style: AppFonts.inter(size: 12, color: AppColors.accent)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ListenableBuilder(
                listenable: _attachments,
                builder: (context, _) => _attachments.isEmpty
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AttachmentStrip(
                            items: _attachments.items,
                            enabled: !_sending,
                            onEdit: _editAttachment,
                            onRemove: (a) => _attachments.remove(a.id),
                          ),
                          if (_progress != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(6, 0, 0, 6),
                              child: Text(_progress!, style: AppText.caption),
                            ),
                        ],
                      ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Images are copied over the host's shell: SSH hosts only.
                  if (host?.hasShell ?? true) ...[
                    RoundIconButton(
                      icon: Icons.add,
                      label: 'Adjuntar imagen',
                      bg: AppColors.surface,
                      border: AppColors.border,
                      fg: AppColors.secondary,
                      iconSize: 20,
                      onPressed: _sending ? null : _pickSource,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: TextField(
                      key: const ValueKey('composer'),
                      controller: _input,
                      focusNode: widget.composerFocus,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      style: AppFonts.inter(size: 14.5),
                      decoration:
                          AppTextField.decoration(
                            hint: 'Mensaje, / comandos, @ ficheros',
                            radius: 22,
                            padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
                          ).copyWith(
                            semanticCounterText: 'Mensaje para el agente',
                            hintMaxLines: 1,
                            suffixIcon: DictationButton(controller: _input, focusNode: widget.composerFocus),
                          ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      RoundIconButton(
                        icon: Icons.arrow_upward,
                        label: _sending ? 'Enviando' : 'Enviar',
                        bg: AppColors.accent,
                        fg: AppColors.bg,
                        iconSize: 20,
                        onPressed: _sending ? null : _send,
                      ),
                      if (_progress != null)
                        IgnorePointer(
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppColors.bg,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Toast text for a failed prompt, by the daemon's error code.
String sendErrorMessage(Object e) {
  final code = e is AgentdError ? e.code : '';
  return switch (code) {
    AgentdErrorCode.busy => _busyMessage(e is AgentdError ? e.data : null),
    AgentdErrorCode.notReady => 'El agente está trabajando o esperando una respuesta: espera a que quede libre',
    AgentdErrorCode.verifyFailed =>
      'El agente no mostró el texto pegado y no se pulsó Enter. Puede haber quedado en su entrada: revisa la terminal antes de reintentar',
    AgentdErrorCode.conflict => 'La pantalla del agente cambió: revisa la vista y reintenta',
    AgentdErrorCode.timeout => 'El agente no responde',
    AgentdErrorCode.exited => 'La sesión ha terminado',
    AgentdErrorCode.forbidden => 'Este dispositivo no tiene permiso para esto en el host',
    AgentdErrorCode.invalid => 'El texto está vacío o es demasiado largo (máx. 64 KiB)',
    _ => 'No se pudo enviar',
  };
}

/// A busy error by its reason (`data.reason`; daemons before 0.5.1 send none).
String _busyMessage(Object? data) {
  final reason = data is Map ? data['reason'] : null;
  return switch (reason) {
    'input' => 'El agente ya tiene texto en su entrada (quizá de un envío anterior). Envíalo o bórralo en la terminal y reintenta',
    'draft' => 'Hay un borrador sin enviar en la entrada del agente (tecleado en la terminal o pegado sin Enter). Envíalo o bórralo en la terminal',
    'human' => 'Acabas de teclear en la terminal; espera unos segundos y reintenta',
    'lock' => 'El agente está recibiendo otra entrada (un mensaje o acción); reintenta en un momento',
    _ => 'Hay texto pendiente en la entrada del agente o acabas de teclear en la terminal',
  };
}

/// Short, safe text for a failure toast (never the stack, bytes or prompt).
String errorReason(Object e) {
  var t = e is StateError ? e.message : e.toString();
  t = t
      .replaceFirst(RegExp(r'^[A-Za-z]*(Exception|Error): '), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return 'error desconocido';
  return t.length > 100 ? '${t.substring(0, 99)}…' : t;
}

/// One transcript entry.
class ChatItemView extends StatelessWidget {
  const ChatItemView({super.key, required this.item});
  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    switch (item.role) {
      case ChatRole.user:
        return Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width * 0.82),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.accentBg,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Consumer(
                builder: (context, ref, _) {
                  final font = ref.watch(settingsProvider.select((s) => (s.chatFont, s.chatFontSize, s.chatLineHeight)));
                  return LinkifiedText(item.text, style: AppFonts.chat(font.$1, size: font.$2, height: 1.45 * font.$3.factor));
                },
              ),
            ),
          ),
        );
      case ChatRole.agent:
        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width * 0.92),
            child: _AgentText(item.text),
          ),
        );
      case ChatRole.tool:
        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width * 0.92),
            child: ToolItemView(item: item),
          ),
        );
      case ChatRole.system:
        return Center(
          child: Text(item.text, style: AppText.caption, textAlign: TextAlign.center),
        );
    }
  }
}

/// Tool call: collapsible when it has output, a plain row otherwise.
class ToolItemView extends StatefulWidget {
  const ToolItemView({super.key, required this.item});
  final ChatItem item;

  @override
  State<ToolItemView> createState() => _ToolItemViewState();
}

class _ToolItemViewState extends State<ToolItemView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final hasBody = item.text.trim().isNotEmpty;
    final icon = switch (item.ok) {
      true => Icon(Icons.check, size: 16, color: AppColors.success),
      false => Icon(Icons.close, size: 16, color: AppColors.danger),
      null => Icon(Icons.description_outlined, size: 16, color: AppColors.muted),
    };
    final head = SizedBox(
      height: 44,
      child: Row(
        children: [
          icon,
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              item.title ?? 'herramienta',
              style: AppFonts.mono(size: 13, color: AppColors.secondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (item.meta != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.meta!,
                style: AppFonts.inter(size: 12, color: AppColors.muted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),
          if (hasBody) Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: AppColors.muted),
        ],
      ),
    );
    return Semantics(
      container: true,
      button: hasBody,
      expanded: hasBody ? _open : null,
      label: '${item.title ?? 'herramienta'}${item.meta != null ? ', ${item.meta}' : ''}${item.ok == false ? ', falló' : ''}',
      excludeSemantics: !_open,
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: hasBody ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                head,
                if (_open && hasBody)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(item.text, style: AppFonts.mono(size: 11.5, color: AppColors.muted, height: 1.45)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The question / permission the agent waits on, with numbered options.
class PendingCard extends StatefulWidget {
  const PendingCard({super.key, required this.pending, required this.onAnswer, required this.onWriteOther});
  final PendingInteraction pending;
  final Future<void> Function(SessionOption) onAnswer;
  final VoidCallback onWriteOther;

  @override
  State<PendingCard> createState() => _PendingCardState();
}

class _PendingCardState extends State<PendingCard> {
  String? _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.pending.options.where((o) => o.selected).firstOrNull?.id;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pending;
    final permission = isPermission(p);
    final selected = p.options.where((o) => o.id == _selected).firstOrNull;
    return Semantics(
      container: true,
      label: 'Pregunta del agente',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.questionBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.questionBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionLabel(pendingLabel(p), color: AppColors.waiting),
            const SizedBox(height: 10),
            if (permission && p.detail != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(10)),
                child: Text(p.detail!, style: AppFonts.mono(size: 13, color: AppColors.text, height: 1.45)),
              ),
              if (p.question.isNotEmpty) const SizedBox(height: 8),
            ],
            if (!permission || p.detail == null || p.question.isNotEmpty)
              permission
                  ? Text(p.question, style: AppFonts.mono(size: 13, color: AppColors.text, height: 1.45))
                  : InlineCodeText(p.question, style: AppFonts.inter(size: 15, weight: FontWeight.w500, height: 1.4)),
            for (final (i, o) in p.options.indexed) ...[
              const SizedBox(height: 10),
              OptionButton(
                number: '${o.index ?? i + 1}',
                label: o.kind == OptionKind.checkbox && o.checked != null ? '${o.checked! ? '☑' : '☐'} ${o.label}' : o.label,
                selected: o.id == _selected,
                onTap: _busy ? null : () => setState(() => _selected = o.id),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: 'Responder',
                    style: AppButtonStyle.waiting,
                    expand: true,
                    onPressed: selected == null || _busy
                        ? null
                        : () async {
                            setState(() => _busy = true);
                            await widget.onAnswer(selected);
                            if (mounted) setState(() => _busy = false);
                          },
                  ),
                ),
                const SizedBox(width: 8),
                AppButton(label: 'Escribir otra', style: AppButtonStyle.outline, onPressed: widget.onWriteOther),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Agent text: prose with links and code, and tables as real tables.
class _AgentText extends ConsumerWidget {
  const _AgentText(this.text);
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final font = ref.watch(settingsProvider.select((s) => (s.chatFont, s.chatFontSize, s.chatLineHeight)));
    final segs = parseChatSegments(text);
    Widget prose(String t) => MarkupText(t, style: AppFonts.chat(font.$1, size: font.$2, height: 1.5 * font.$3.factor), codeColor: AppColors.accentLight);
    if (segs.length <= 1 && (segs.isEmpty || segs.first is TextSegment)) return prose(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, s) in segs.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          switch (s) {
            TextSegment() => prose(s.text),
            CodeSegment() => ChatCodeBlock(code: s.code, fontSize: font.$2 - 2),
            TableSegment() => ChatTableView(
              table: ChatTable(
                header: s.table.header?.map(unmarkup).toList(),
                rows: [for (final r in s.table.rows) r.map(unmarkup).toList()],
              ),
            ),
          },
        ],
      ],
    );
  }
}
