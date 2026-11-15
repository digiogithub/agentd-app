// Agents inbox: every session of every host grouped by what it needs.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/session_card.dart';
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

  void _open(AgentSession s) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SessionScreen(session: s)));

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider);
    final hosts = ref.watch(hostsProvider).value ?? const <HostStatus>[];
    final names = ref.watch(hostNamesProvider);
    final all = sessions.value ?? const <AgentSession>[];
    final online = hosts.where((h) => h.state == HostState.online).length;

    final visible = _query.isEmpty ? all : all.where((s) => sessionTitle(s).toLowerCase().contains(_query.toLowerCase())).toList();
    final groups = {for (final g in SessionGroup.values) g: visible.where((s) => groupOf(s) == g).toList()};
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

    section(SessionGroup.needsAnswer, 'Necesitan respuesta', AppColors.waiting);
    section(SessionGroup.working, 'Trabajando', AppColors.working);
    section(SessionGroup.done, 'Listos', AppColors.muted);

    return SafeArea(
      bottom: false,
      child: Stack(
        children: [
          Column(
            children: [
              ScreenHeader(
                overline: '${plural(online, 'host', 'hosts')} · ${plural(all.length, 'sesión', 'sesiones')}',
                title: 'Agentes',
                trailing: RoundIconButton(
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
                bottom: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_searching) ...[
                      AppTextField(hint: 'Buscar sesión', onChanged: (v) => setState(() => _query = v), semanticLabel: 'Buscar sesión'),
                      const SizedBox(height: 10),
                    ],
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
                  ],
                ),
              ),
              Expanded(
                child: sessions.isLoading && all.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : children.isEmpty
                    ? _empty()
                    : ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 96), children: children),
              ),
            ],
          ),
          Positioned(
            right: 18,
            bottom: 20,
            child: AppFab(
              label: 'Nueva sesión',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NewSessionScreen(), fullscreenDialog: true)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(AgentSession s, String hostName) {
    final p = s.pending;
    if (p != null && isPermission(p)) {
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
