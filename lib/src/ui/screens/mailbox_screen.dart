// agentd mailbox of a host: messages between agents and work queues.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

enum MailTab { messages, queues }

class MailboxScreen extends ConsumerStatefulWidget {
  const MailboxScreen({super.key, this.hostId, this.pushed = false});
  final String? hostId;

  /// Opened as a route (back button) instead of a bottom-nav tab.
  final bool pushed;

  @override
  ConsumerState<MailboxScreen> createState() => _MailboxScreenState();
}

class _MailboxScreenState extends ConsumerState<MailboxScreen> {
  MailTab _tab = MailTab.messages;
  String? _hostId;

  @override
  void initState() {
    super.initState();
    _hostId = widget.hostId;
  }

  List<HostStatus> _mailHosts(List<HostStatus> hosts) => hosts.where((h) => h.state == HostState.online && (h.capabilities?.has('agentd') ?? false)).toList();

  Future<void> _pickHost(List<HostStatus> hosts) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final h in hosts)
              ListTile(
                title: Text(h.config.name, style: AppFonts.inter(size: 15, weight: FontWeight.w600)),
                trailing: h.config.id == _hostId ? const Icon(Icons.check, color: AppColors.accent) : null,
                onTap: () => Navigator.pop(ctx, h.config.id),
              ),
          ],
        ),
      ),
    );
    if (id != null) setState(() => _hostId = id);
  }

  Future<void> _compose(String hostId, List<String> targets) async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ComposeSheet(hostId: hostId, targets: targets),
    );
    if ((sent ?? false) && mounted) showToast(context, 'Mensaje enviado');
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _mailHosts(ref.watch(hostsProvider).value ?? const []);
    final host = hosts.where((h) => h.config.id == _hostId).firstOrNull ?? hosts.firstOrNull;
    final hostId = host?.config.id;
    final messages = hostId == null ? const <MailMessage>[] : (ref.watch(inboxProvider(hostId)).value ?? const <MailMessage>[]);
    final queues = hostId == null ? const <WorkQueue>[] : (ref.watch(queuesProvider(hostId)).value ?? const <WorkQueue>[]);
    final sessions = ref.watch(sessionsProvider).value ?? const <AgentSession>[];

    final direct = messages.where((m) => m.queue == null && m.replyTo == null).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final replies = <int, List<MailMessage>>{};
    for (final m in messages.where((m) => m.replyTo != null)) {
      (replies[m.replyTo!] ??= []).add(m);
    }

    final targets = [
      for (final s in sessions.where((s) => s.hostId == hostId && s.source == SessionSource.agentd)) s.name,
      for (final q in queues) 'queue:${q.name}',
    ];

    final overline = GestureDetector(
      onTap: hosts.length > 1 ? () => _pickHost(hosts) : null,
      child: Semantics(
        container: true,
        button: hosts.length > 1,
        label: 'Host del buzón: ${host?.config.name ?? 'ninguno'}',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text('Mensajes entre agentes · ${host?.config.name ?? 'sin host'}', style: AppText.overline, overflow: TextOverflow.ellipsis),
            ),
            if (hosts.length > 1) const Icon(Icons.expand_more, size: 16, color: AppColors.muted),
          ],
        ),
      ),
    );

    final body = Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(widget.pushed ? 12 : 20, widget.pushed ? 14 : 20, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (widget.pushed) ...[
                        RoundIconButton(icon: Icons.chevron_left, label: 'Volver', onPressed: () => Navigator.of(context).maybePop()),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            overline,
                            const SizedBox(height: 2),
                            Semantics(header: true, child: Text('Buzón', style: AppText.screenTitle)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SegmentedControl<MailTab>(
                    options: [(MailTab.messages, 'Mensajes · ${direct.length}'), (MailTab.queues, 'Colas · ${queues.length}')],
                    value: _tab,
                    onChanged: (t) => setState(() => _tab = t),
                  ),
                ],
              ),
            ),
            Expanded(
              child: hostId == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'El buzón necesita un host con agentd en línea.',
                          textAlign: TextAlign.center,
                          style: AppText.body.copyWith(color: AppColors.muted),
                        ),
                      ),
                    )
                  : _tab == MailTab.messages
                  ? _list([for (final m in direct) _MessageCard(message: m, replies: replies[m.id] ?? const [])], 'No hay mensajes')
                  : _list([for (final q in queues) _QueueCard(queue: q, items: messages.where((m) => m.queue == q.name).toList())], 'No hay colas'),
            ),
          ],
        ),
        if (hostId != null)
          Positioned(
            right: 18,
            bottom: 20,
            child: AppFab(label: 'Enviar a agente o cola', icon: Icons.send_outlined, onTap: () => _compose(hostId, targets)),
          ),
      ],
    );

    return widget.pushed ? Scaffold(body: SafeArea(child: body)) : SafeArea(bottom: false, child: body);
  }

  Widget _list(List<Widget> cards, String empty) => cards.isEmpty
      ? Center(
          child: Text(empty, style: AppText.body.copyWith(color: AppColors.muted)),
        )
      : ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
          itemCount: cards.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (_, i) => cards[i],
        );
}

String _who(String id) => id.startsWith('human:') ? 'tú' : id;

(String, Color, Color) _stateLook(MailState s) => switch (s) {
  MailState.queued => ('En cola', AppColors.waiting, AppColors.onWaiting),
  MailState.replied => ('Respondido', AppColors.accent, AppColors.onWorking),
  MailState.read => ('Leído', AppColors.raised, AppColors.secondary),
  MailState.delivered => ('Entregado', AppColors.workingBg, AppColors.working),
  MailState.unclaimed => ('Sin reclamar', AppColors.waitingBg, AppColors.waiting),
};

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message, required this.replies});
  final MailMessage message;
  final List<MailMessage> replies;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final (label, bg, fg) = _stateLook(m.state);
    final from = _who(m.from);
    final text = m.body.isNotEmpty ? m.body : m.subject;
    final foot = m.state == MailState.queued ? '#${m.id} · se entregará cuando ${m.to} quede libre' : '#${m.id} · ${relativeTime(m.createdAt)}';
    return AppCard(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      semanticLabel: 'Mensaje ${m.id} de $from a ${m.to}, $label',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        from,
                        style: AppFonts.mono(size: 13, color: from == 'tú' ? AppColors.secondary : AppColors.accentLight),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.arrow_forward, size: 14, color: AppColors.muted),
                    ),
                    Flexible(
                      child: Text(
                        _who(m.to),
                        style: AppFonts.mono(size: 13, color: AppColors.accentLight),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(label, bg: bg, fg: fg),
            ],
          ),
          const SizedBox(height: 6),
          Text(text, style: AppFonts.inter(size: 14, height: 1.45)),
          for (final r in replies) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.only(left: 10),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: AppColors.border, width: 2)),
              ),
              child: Text(r.body.isNotEmpty ? r.body : r.subject, style: AppFonts.inter(size: 13, color: AppColors.secondary, height: 1.4)),
            ),
          ],
          const SizedBox(height: 6),
          Text(foot, style: AppText.caption),
        ],
      ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.queue, required this.items});
  final WorkQueue queue;
  final List<MailMessage> items;

  @override
  Widget build(BuildContext context) {
    final unclaimed = items.where((m) => m.state == MailState.unclaimed).toList();
    final claimed = items.where((m) => m.state != MailState.unclaimed).toList();
    return AppCard(
      radius: 16,
      semanticLabel: 'Cola ${queue.name}, ${queue.unclaimed} sin reclamar',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'queue:${queue.name}',
                  style: AppFonts.mono(size: 15, weight: FontWeight.w500, color: AppColors.text),
                ),
              ),
              Text(
                '${queue.unclaimed} sin reclamar',
                style: AppFonts.inter(
                  size: 13,
                  weight: queue.unclaimed > 0 ? FontWeight.w600 : FontWeight.w400,
                  color: queue.unclaimed > 0 ? AppColors.waiting : AppColors.muted,
                ),
              ),
            ],
          ),
          if (unclaimed.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final m in unclaimed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '#${m.id} · ${m.subject.isNotEmpty ? m.subject : m.body} · de ${_who(m.from)}',
                  style: AppFonts.inter(size: 13, color: AppColors.secondary),
                ),
              ),
          ],
          for (final m in claimed) ...[
            const SizedBox(height: 10),
            Text('#${m.id} reclamado por ${_who(m.to)} ${relativeTime(m.createdAt)}', style: AppFonts.inter(size: 13, color: AppColors.secondary)),
          ],
        ],
      ),
    );
  }
}

class _ComposeSheet extends ConsumerStatefulWidget {
  const _ComposeSheet({required this.hostId, required this.targets});
  final String hostId;
  final List<String> targets;

  @override
  ConsumerState<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends ConsumerState<_ComposeSheet> {
  late final _to = TextEditingController(text: widget.targets.firstOrNull ?? '');
  final _body = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _to.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final to = _to.text.trim();
    final body = _body.text.trim();
    if (to.isEmpty || body.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(mailRepositoryProvider).send(widget.hostId, to: to, body: body);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, 'No se pudo enviar a $to');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Enviar a agente o cola', style: AppText.routeTitle),
        const SizedBox(height: 12),
        if (widget.targets.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final t in widget.targets)
                FilterPill(label: t, mono: true, selected: _to.text == t, height: 34, radius: 10, onTap: () => setState(() => _to.text = t)),
            ],
          ),
        const SizedBox(height: 8),
        LabeledField(
          label: 'Para',
          child: AppTextField(controller: _to, mono: true, hint: 'claude@webapp o queue:review', onChanged: (_) => setState(() {})),
        ),
        const SizedBox(height: 10),
        LabeledField(
          label: 'Mensaje',
          child: AppTextField(controller: _body, hint: 'Qué necesitas'),
        ),
        const SizedBox(height: 14),
        AppButton(label: _busy ? 'Enviando…' : 'Enviar', height: 52, radius: 14, expand: true, bold: true, fontSize: 15, onPressed: _busy ? null : _send),
      ],
    ),
  );
}
