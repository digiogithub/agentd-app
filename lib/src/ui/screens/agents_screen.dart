// Agents inbox: every session of every host grouped by what it needs, and
// the selection mode that sends one prompt to several agents at once.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../providers.dart';
import '../terminate.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/session_card.dart';
import 'chat_tab.dart' show sendErrorMessage;
import 'new_session_screen.dart';
import 'session_screen.dart';

enum AgentsFilter { all, waiting, working, done }

class AgentsScreen extends ConsumerStatefulWidget {
  const AgentsScreen({super.key});

  @override
  ConsumerState<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends ConsumerState<AgentsScreen> {
  AgentsFilter _filter = AgentsFilter.all;
  bool _searching = false;
  String _query = '';
  final Set<String> _busy = {};

  // Selection mode (broadcast prompt): picked session keys, the draft and
  // the outcome of the last send.
  bool _selecting = false;
  final Set<String> _picked = {};
  final _draft = TextEditingController();
  bool _sending = false;
  String? _sendError;
  // Keys of the sessions a prompt can be sent to, as of the last build.
  Set<String> _selectable = const {};

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  void _toggleSelecting() => setState(() {
    _selecting = !_selecting;
    _picked.clear();
    _sendError = null;
  });

  /// Why a prompt cannot be sent to [s] from the list; null = selectable.
  String? _pickBlock(AgentSession s, bool canOperate) {
    if (s.source != SessionSource.agentd) return 'no admite prompts desde aquí';
    if (s.status == AgentStatus.exited) return 'sesión terminada';
    if (s.status == AgentStatus.starting) return 'arrancando';
    if (!canOperate) return 'solo lectura en este dispositivo';
    return null;
  }

  /// The picked sessions still listed and selectable, in a stable order.
  List<AgentSession> _targets() {
    final all = ref.read(sessionsProvider).value ?? const <AgentSession>[];
    return all.where((s) => _picked.contains(s.key) && _selectable.contains(s.key)).toList()..sort((a, b) => a.key.compareTo(b.key));
  }

  /// Sends the draft as a prompt to every picked session, in parallel (the
  /// repository forces it only while that agent works, as the chat does).
  /// Sessions that took it are unselected; refusals stay selected and named.
  Future<void> _sendAll() async {
    final text = _draft.text.trim();
    final targets = _targets();
    if (text.isEmpty || targets.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    final repo = ref.read(sessionsRepositoryProvider);
    final errors = await Future.wait(
      targets.map((s) async {
        try {
          await repo.prompt(s, text);
          return null;
        } catch (e) {
          return e;
        }
      }),
    );
    if (!mounted) return;
    final failed = <String>[];
    Object? firstError;
    var sent = 0;
    for (final (i, e) in errors.indexed) {
      if (e == null) {
        sent++;
        _picked.remove(targets[i].key);
      } else {
        failed.add(sessionTitle(targets[i]));
        firstError ??= e;
      }
    }
    setState(() {
      _sending = false;
      if (failed.isEmpty) {
        if (_draft.text.trim() == text) _draft.clear();
        _selecting = false;
        _picked.clear();
      } else {
        failed.sort();
        _sendError = 'No se pudo enviar a ${failed.join(', ')}: ${sendErrorMessage(firstError!)}';
      }
    });
    if (sent > 0) showToast(context, 'Prompt enviado a ${plural(sent, 'agente', 'agentes')}');
  }

  Future<void> _answer(AgentSession s, SessionOption? option) async {
    final p = s.pending;
    if (option == null || p == null) return;
    final rev = p.revision;
    final epoch = p.epoch;
    if (rev == null || epoch == null) {
      showToast(context, 'Sin revisión del menú: abre la sesión para responder');
      return;
    }
    setState(() => _busy.add(s.key));
    try {
      await ref.read(sessionsRepositoryProvider).choose(s, option, revision: rev, epoch: epoch);
    } catch (e) {
      if (mounted) showToast(context, 'No se pudo responder: el menú cambió o la sesión no está lista');
    } finally {
      if (mounted) setState(() => _busy.remove(s.key));
    }
  }

  Future<void> _sessionMenu(AgentSession s) async {
    // Terminar is the only action: relay devices below admin have none.
    if (!(ref.read(hostConfigProvider(s.hostId))?.canAdmin ?? true)) return;
    final terminate = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(sessionTitle(s), style: AppText.caption, overflow: TextOverflow.ellipsis),
              ),
            ),
            ListTile(
              leading: Icon(Icons.delete_forever_outlined, color: AppColors.danger),
              title: Text('Terminar', style: AppFonts.inter(size: 15, color: AppColors.danger)),
              subtitle: Text('Forzar cierre y borrar la sesión', style: AppText.caption),
              onTap: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      ),
    );
    if (terminate == true && mounted) await confirmTerminate(context, ref, s);
  }

  void _newSession({String? hostId, String? project}) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => NewSessionScreen(hostId: hostId, project: project),
      fullscreenDialog: true,
    ),
  );

  void _open(AgentSession s) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SessionScreen(session: s)));

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider);
    final hosts = ref.watch(hostsProvider).value ?? const <HostStatus>[];
    final names = ref.watch(hostNamesProvider);
    final all = sessions.value ?? const <AgentSession>[];
    final online = hosts.where((h) => h.state == HostState.online).length;

    final visible = _query.isEmpty ? all : all.where((s) => sessionTitle(s).toLowerCase().contains(_query.toLowerCase())).toList();
    final groups = {for (final g in SessionGroup.values) g: visible.where((s) => groupOf(s) == g).toList()..sort(compareSessions)};
    int count(SessionGroup g) => groups[g]!.length;

    final chips = [
      (AgentsFilter.all, 'Todos · ${visible.length}'),
      (AgentsFilter.waiting, 'Esperan · ${count(SessionGroup.needsAnswer)}'),
      (AgentsFilter.working, 'Trabajando · ${count(SessionGroup.working)}'),
      (AgentsFilter.done, 'Listos · ${count(SessionGroup.done)}'),
    ];

    bool show(SessionGroup g) => switch (_filter) {
      AgentsFilter.all => true,
      AgentsFilter.waiting => g == SessionGroup.needsAnswer,
      AgentsFilter.working => g == SessionGroup.working,
      AgentsFilter.done => g == SessionGroup.done,
    };

    // Selection mode: what can be picked, and the quick picks over the
    // sessions shown (filter and search apply).
    final blocks = <String, String?>{
      if (_selecting)
        for (final s in all) s.key: _pickBlock(s, ref.watch(hostConfigProvider(s.hostId))?.canOperate ?? true),
    };
    _selectable = {
      for (final e in blocks.entries)
        if (e.value == null) e.key,
    };
    final pickable = visible.where((s) => show(groupOf(s)) && _selectable.contains(s.key)).toList();
    final pickHosts = {for (final s in pickable) s.hostId}.toList()..sort();
    final targetCount = all.where((s) => _picked.contains(s.key) && _selectable.contains(s.key)).length;

    final children = <Widget>[];
    void section(SessionGroup g, String title, Color color) {
      final list = groups[g]!;
      if (!show(g) || list.isEmpty) return;
      children.add(SectionLabel('$title · ${list.length}', color: color, padding: EdgeInsets.fromLTRB(4, children.isEmpty ? 4 : 8, 4, 0)));
      for (final s in list) {
        children.add(const SizedBox(height: 10));
        children.add(_card(s, names[s.hostId] ?? ''));
      }
      children.add(const SizedBox(height: 10));
    }

    final grouping = ref.watch(settingsProvider.select((s) => s.agentsGrouping));
    if (grouping == AgentsGrouping.status) {
      section(SessionGroup.needsAnswer, 'Necesitan respuesta', AppColors.waiting);
      section(SessionGroup.working, 'Trabajando', AppColors.working);
      section(SessionGroup.done, 'Listos', AppColors.muted);
    } else {
      final shown = visible.where((s) => show(groupOf(s)));
      for (final g in groupByProject(shown)) {
        final canStart = ref.watch(hostConfigProvider(g.hostId))?.canAdmin ?? true;
        children.add(
          _ProjectHeader(
            group: g,
            hostName: hosts.length > 1 ? (names[g.hostId] ?? '') : '',
            onAdd: canStart ? () => _newSession(hostId: g.hostId, project: g.hasProject ? g.path : null) : null,
          ),
        );
        for (final s in g.sessions) {
          children.add(const SizedBox(height: 10));
          children.add(_card(s, names[s.hostId] ?? ''));
        }
        children.add(const SizedBox(height: 10));
      }
    }

    return SafeArea(
      bottom: false,
      child: Stack(
        children: [
          Column(
            children: [
              ScreenHeader(
                overline: '${plural(online, 'host', 'hosts')} · ${plural(all.length, 'sesión', 'sesiones')}',
                title: 'Agentes',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RoundIconButton(
                      key: const ValueKey('select-mode'),
                      icon: _selecting ? Icons.close : Icons.checklist,
                      label: _selecting ? 'Salir de la selección' : 'Seleccionar varios',
                      bg: _selecting ? AppColors.accentBg : AppColors.surface,
                      border: _selecting ? AppColors.accent : AppColors.border,
                      iconSize: 20,
                      onPressed: _sending ? null : _toggleSelecting,
                    ),
                    const SizedBox(width: 8),
                    RoundIconButton(
                      icon: _searching ? Icons.close : Icons.search,
                      label: _searching ? 'Cerrar búsqueda' : 'Buscar',
                      bg: AppColors.surface,
                      border: AppColors.border,
                      iconSize: 20,
                      onPressed: () => setState(() {
                        _searching = !_searching;
                        if (!_searching) _query = '';
                      }),
                    ),
                  ],
                ),
                bottom: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_searching) ...[
                      AppTextField(hint: 'Buscar sesión', onChanged: (v) => setState(() => _query = v), semanticLabel: 'Buscar sesión'),
                      const SizedBox(height: 10),
                    ],
                    SegmentedControl<AgentsGrouping>(
                      height: 34,
                      options: const [(AgentsGrouping.project, 'Proyecto'), (AgentsGrouping.status, 'Estado')],
                      value: grouping,
                      onChanged: (g) => ref.read(settingsProvider.notifier).update((st) => st.copyWith(agentsGrouping: g)),
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final (i, (f, label)) in chips.indexed) ...[
                            if (i > 0) const SizedBox(width: 8),
                            FilterPill(label: label, selected: _filter == f, onTap: () => setState(() => _filter = f)),
                          ],
                        ],
                      ),
                    ),
                    if (_selecting)
                      SingleChildScrollView(
                        key: const ValueKey('pick-bar'),
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            Text('Seleccionar:', style: AppText.caption),
                            const SizedBox(width: 8),
                            FilterPill(
                              key: const ValueKey('pick-all'),
                              label: 'Mostrados · ${pickable.length}',
                              selected: false,
                              onTap: () => setState(() => _picked.addAll(pickable.map((s) => s.key))),
                            ),
                            if (pickHosts.length > 1)
                              for (final h in pickHosts) ...[
                                const SizedBox(width: 8),
                                FilterPill(
                                  key: ValueKey('pick-host:$h'),
                                  label: '${names[h] ?? h} · ${pickable.where((s) => s.hostId == h).length}',
                                  selected: false,
                                  onTap: () => setState(() => _picked.addAll(pickable.where((s) => s.hostId == h).map((s) => s.key))),
                                ),
                              ],
                            const SizedBox(width: 8),
                            FilterPill(key: const ValueKey('pick-none'), label: 'Ninguno', selected: false, onTap: () => setState(_picked.clear)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: sessions.isLoading && all.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : children.isEmpty
                    ? _empty()
                    : ListView(padding: EdgeInsets.fromLTRB(16, 0, 16, _selecting ? 12 : 96), children: children),
              ),
              if (_selecting) _broadcastBar(targetCount),
            ],
          ),
          if (!_selecting)
            Positioned(
              right: 18,
              bottom: 20,
              child: AppFab(label: 'Nueva sesión', onTap: () => _newSession()),
            ),
        ],
      ),
    );
  }

  Widget _card(AgentSession s, String hostName) {
    if (_selecting) {
      return PickRow(
        key: ValueKey('pick-${s.key}'),
        session: s,
        hostName: hostName,
        picked: _picked.contains(s.key),
        reason: _selectable.contains(s.key) ? null : _pickBlock(s, ref.watch(hostConfigProvider(s.hostId))?.canOperate ?? true),
        onToggle: () => setState(() => _picked.contains(s.key) ? _picked.remove(s.key) : _picked.add(s.key)),
      );
    }
    return GestureDetector(key: ValueKey('press-${s.key}'), onLongPress: () => _sessionMenu(s), child: _cardBody(s, hostName));
  }

  /// Composer of the selection mode, docked under the list.
  Widget _broadcastBar(int n) => Container(
    key: const ValueKey('broadcast-bar'),
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
    decoration: BoxDecoration(
      color: AppColors.bg,
      border: Border(top: BorderSide(color: AppColors.divider)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(n > 0 ? plural(n, 'agente seleccionado', 'agentes seleccionados') : 'Elige a quién enviar el prompt', style: AppText.caption),
        if (_sendError != null) ...[
          const SizedBox(height: 4),
          Text(
            _sendError!,
            key: const ValueKey('broadcast-error'),
            style: AppText.caption.copyWith(color: AppColors.danger),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('broadcast-text'),
                controller: _draft,
                enabled: !_sending,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                style: AppFonts.inter(size: 15),
                decoration: AppTextField.decoration(
                  hint: 'Prompt para los seleccionados',
                  radius: 22,
                ).copyWith(semanticCounterText: 'Prompt para los agentes seleccionados'),
              ),
            ),
            const SizedBox(width: 8),
            AppButton(
              key: const ValueKey('broadcast-send'),
              label: _sending ? 'Enviando…' : (n > 0 ? 'Enviar a $n' : 'Enviar'),
              style: AppButtonStyle.accent,
              onPressed: _sending || n == 0 || _draft.text.trim().isEmpty ? null : _sendAll,
            ),
          ],
        ),
      ],
    ),
  );

  Widget _cardBody(AgentSession s, String hostName) {
    final p = s.pending;
    final canOperate = ref.watch(hostConfigProvider(s.hostId))?.canOperate ?? true;
    if (p != null && isPermission(p) && canOperate) {
      return ApprovalCard(
        key: ValueKey('approval-${s.key}'),
        session: s,
        hostName: hostName,
        busy: _busy.contains(s.key),
        onAllow: () => _answer(s, allowOption(p)),
        onDeny: () => _answer(s, denyOption(p)),
        onOpen: () => _open(s),
      );
    }
    if (groupOf(s) == SessionGroup.needsAnswer) {
      return QuestionCard(key: ValueKey('question-${s.key}'), session: s, hostName: hostName, onOpen: () => _open(s));
    }
    return SessionRow(key: ValueKey('row-${s.key}'), session: s, hostName: hostName, onOpen: () => _open(s));
  }

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        _query.isNotEmpty ? 'Ninguna sesión coincide' : 'No hay sesiones en este filtro. Lanza una con «Nueva sesión».',
        textAlign: TextAlign.center,
        style: AppText.body.copyWith(color: AppColors.muted),
      ),
    ),
  );
}

/// Header of a project group: directory, host, count, attention and `+`.
class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.group, required this.hostName, this.onAdd});
  final ProjectGroup group;
  final String hostName;

  /// Null when the host does not let this device start sessions.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final attn = group.needsAnswer;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 0),
      child: Row(
        children: [
          Icon(group.hasProject ? Icons.folder_outlined : Icons.folder_off_outlined, size: 18, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: group.label,
                      style: group.hasProject ? AppFonts.mono(size: 13, weight: FontWeight.w600) : AppFonts.inter(size: 13, weight: FontWeight.w600),
                    ),
                    if (hostName.isNotEmpty)
                      TextSpan(
                        text: '  $hostName',
                        style: AppFonts.inter(size: 12, color: AppColors.muted),
                      ),
                    TextSpan(
                      text: '  · ${group.sessions.length}',
                      style: AppFonts.inter(size: 12, color: AppColors.muted),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (attn > 0) ...[
            Semantics(
              label: attn == 1 ? '1 sesión necesita respuesta' : '$attn sesiones necesitan respuesta',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: AppColors.waitingBg, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  '$attn',
                  style: AppFonts.inter(size: 11, weight: FontWeight.w700, color: AppColors.waiting),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          if (onAdd != null)
            RoundIconButton(
              icon: Icons.add,
              label: group.hasProject ? 'Nueva sesión en ${group.label}' : 'Nueva sesión',
              bg: AppColors.surface,
              border: AppColors.border,
              iconSize: 18,
              onPressed: onAdd,
            ),
        ],
      ),
    );
  }
}
