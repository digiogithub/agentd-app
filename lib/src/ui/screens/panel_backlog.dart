// Backlog of a host in the Panel: notes the human writes down (ideas, future
// tasks) and later hands to a running agent of the same host, where they
// become a pending or in-progress task. Only the human manages notes; the
// daemon stores them.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/panel_widgets.dart';

/// User-facing (Spanish) text for a refused backlog change. [assigning]
/// picks the words of an assignment.
String backlogErrorText(Object e, {bool assigning = false}) {
  if (e is! BacklogException) return 'No se pudo guardar: sin conexión con el host';
  return switch (e.failure) {
    BacklogFailure.invalid =>
      assigning ? 'No se pudo asignar: la nota ya está hecha o el agente tiene la lista de tareas llena' : 'El host no aceptó la nota: revisa el título y la longitud del texto',
    BacklogFailure.notFound => assigning ? 'La nota o el agente ya no existen' : 'La nota ya no existe',
    BacklogFailure.sessionNotRunning => 'El agente no está en marcha',
    BacklogFailure.forbidden => 'Este dispositivo no puede usar el backlog de este host',
    BacklogFailure.unavailable => 'El backlog de este host no está disponible',
  };
}

/// The "Backlog" section of one host.
class BacklogSection extends ConsumerStatefulWidget {
  const BacklogSection({super.key, required this.board, this.hostName = ''});
  final HostBoard board;

  /// Shown next to the title when the Panel lists several hosts.
  final String hostName;

  @override
  ConsumerState<BacklogSection> createState() => _BacklogSectionState();
}

class _BacklogSectionState extends ConsumerState<BacklogSection> {
  bool _showDone = false;

  String get _host => widget.board.hostId;

  @override
  Widget build(BuildContext context) {
    final notes = widget.board.notes;
    final live = [for (final n in notes) if (n.state != NoteState.done) n];
    final done = [for (final n in notes) if (n.state == NoteState.done) n];
    return Column(
      key: ValueKey('backlog-$_host'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: SectionLabel(widget.hostName.isEmpty ? 'Backlog' : 'Backlog · ${widget.hostName}', padding: const EdgeInsets.fromLTRB(2, 4, 2, 0)),
            ),
            AppButton(
              key: ValueKey('backlog-add-$_host'),
              label: 'Añadir nota',
              icon: Icons.add,
              style: AppButtonStyle.outline,
              radius: 10,
              fontSize: 13,
              semanticLabel: widget.hostName.isEmpty ? 'Añadir nota al backlog' : 'Añadir nota al backlog de ${widget.hostName}',
              onPressed: () => showNoteSheet(context, hostId: _host),
            ),
          ],
        ),
        if (live.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
            child: Text('Sin notas pendientes. Apunta ideas o tareas futuras y asígnalas después a un agente.', style: AppText.caption),
          ),
        for (final n in live) ...[const SizedBox(height: 10), _NoteCard(hostId: _host, note: n, sessions: widget.board.sessions)],
        if (done.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('backlog-done-$_host'),
              onPressed: () => setState(() => _showDone = !_showDone),
              style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: 2)),
              child: Text(
                _showDone ? 'Ocultar hechas' : (done.length == 1 ? '1 nota hecha' : '${done.length} notas hechas'),
                style: AppFonts.inter(size: 13, color: AppColors.accentLight),
              ),
            ),
          ),
        if (_showDone)
          for (final n in done) ...[_NoteCard(hostId: _host, note: n, sessions: widget.board.sessions), const SizedBox(height: 10)],
      ],
    );
  }
}

String _stateLine(BacklogNote n) => switch (n.state) {
  NoteState.open => n.createdAt == null ? 'Sin asignar' : 'Sin asignar · ${relativeTime(n.createdAt)}',
  NoteState.assigned => 'Asignada a ${n.assignedTo ?? 'un agente'}',
  NoteState.done => 'Hecha por ${n.assignedTo ?? 'un agente'}',
};

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.hostId, required this.note, required this.sessions});
  final String hostId;
  final BacklogNote note;
  final List<BoardSession> sessions;

  @override
  Widget build(BuildContext context) {
    final n = note;
    final done = n.state == NoteState.done;
    return AppCard(
      key: ValueKey('backlog-note-$hostId-${n.id}'),
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      semanticLabel: '${n.title}. ${_stateLine(n)}',
      onTap: () => showNoteSheet(context, hostId: hostId, note: n),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  n.title,
                  style: AppFonts.inter(size: 14, weight: FontWeight.w500, height: 1.35, color: done ? AppColors.secondary : AppColors.text),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (n.body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(n.body, style: AppFonts.inter(size: 12.5, color: AppColors.secondary, height: 1.35), maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 4),
                Text(
                  _stateLine(n),
                  style: AppFonts.inter(size: 12, color: n.state == NoteState.assigned ? AppColors.working : AppColors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (n.state == NoteState.open)
            AppButton(
              key: ValueKey('backlog-assign-$hostId-${n.id}'),
              label: 'Asignar',
              style: AppButtonStyle.soft,
              radius: 10,
              fontSize: 13,
              semanticLabel: 'Asignar: ${n.title}',
              onPressed: () => showAssignSheet(context, hostId: hostId, note: n, sessions: sessions),
            )
          else
            Padding(padding: const EdgeInsets.only(right: 6), child: Icon(Icons.chevron_right, size: 20, color: AppColors.faint)),
        ],
      ),
    );
  }
}

/// New note ([note] null) or edit, reopen, assign and delete of [note].
Future<void> showNoteSheet(BuildContext context, {required String hostId, BacklogNote? note}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
  builder: (_) => NoteSheet(hostId: hostId, note: note),
);

/// Pick a running agent of the note's host and how the task starts.
Future<void> showAssignSheet(BuildContext context, {required String hostId, required BacklogNote note, required List<BoardSession> sessions}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => AssignSheet(hostId: hostId, note: note, sessions: sessions),
    );

class NoteSheet extends ConsumerStatefulWidget {
  const NoteSheet({super.key, required this.hostId, this.note});
  final String hostId;
  final BacklogNote? note;

  @override
  ConsumerState<NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends ConsumerState<NoteSheet> {
  late final _title = TextEditingController(text: widget.note?.title ?? '');
  late final _body = TextEditingController(text: widget.note?.body ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  /// Runs a change, reports its failure, closes the sheet on success.
  Future<void> _run(Future<void> Function(BoardRepository repo) change, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await change(ref.read(boardRepositoryProvider));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, backlogErrorText(e));
      return;
    }
    if (!mounted) return;
    showToast(context, done);
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final body = _body.text.trim();
    if (title.isEmpty) {
      showToast(context, 'Escribe un título');
      return;
    }
    if (title.runes.length > BacklogNote.maxTitle || body.runes.length > BacklogNote.maxBody) {
      showToast(context, 'Demasiado largo: el título admite ${BacklogNote.maxTitle} caracteres y el texto ${BacklogNote.maxBody}');
      return;
    }
    final n = widget.note;
    if (n == null) {
      await _run((r) => r.addNote(widget.hostId, title: title, body: body), 'Nota añadida al backlog');
    } else {
      await _run((r) => r.updateNote(widget.hostId, n.id, title: title == n.title ? null : title, body: body == n.body ? null : body), 'Nota guardada');
    }
  }

  Future<void> _delete(BacklogNote n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Eliminar la nota?', style: AppFonts.inter(size: 18, weight: FontWeight.w600)),
        content: Text(
          n.state == NoteState.assigned ? 'Se borra del backlog. La tarea que ya tiene ${n.assignedTo ?? 'el agente'} no se toca.' : 'Se borra del backlog del host.',
          style: AppText.body,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Eliminar', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if ((ok ?? false) && mounted) await _run((r) => r.removeNote(widget.hostId, n.id), 'Nota eliminada');
  }

  void _assign(BacklogNote n) {
    final sessions = ref.read(boardProvider(widget.hostId)).value?.sessions ?? const <BoardSession>[];
    final nav = Navigator.of(context);
    final ctx = nav.context;
    nav.pop();
    showAssignSheet(ctx, hostId: widget.hostId, note: n, sessions: sessions);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.note;
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
              Semantics(
                header: true,
                child: Text(n == null ? 'Nueva nota' : 'Nota del backlog', style: AppFonts.inter(size: 16, weight: FontWeight.w600)),
              ),
              if (n != null) ...[const SizedBox(height: 2), Text(_stateLine(n), style: AppText.caption)],
              const SizedBox(height: 14),
              LabeledField(
                label: 'Título',
                child: AppTextField(key: const ValueKey('note-title'), controller: _title, hint: 'Qué hay que hacer', enabled: !_busy, textInputAction: TextInputAction.next),
              ),
              const SizedBox(height: 10),
              LabeledField(
                label: 'Detalle (opcional)',
                child: AppTextField(key: const ValueKey('note-body'), controller: _body, hint: 'Contexto para el agente que la reciba', enabled: !_busy, maxLines: 6),
              ),
              const SizedBox(height: 14),
              AppButton(label: n == null ? 'Añadir al backlog' : 'Guardar', expand: true, onPressed: _busy ? null : _save),
              if (n != null) ...[
                const SizedBox(height: 8),
                if (n.state != NoteState.done) AppButton(label: n.state == NoteState.assigned ? 'Asignar a otro agente' : 'Asignar a un agente', style: AppButtonStyle.outline, expand: true, onPressed: _busy ? null : () => _assign(n)),
                if (n.state != NoteState.open) ...[
                  const SizedBox(height: 8),
                  AppButton(
                    label: 'Devolver al backlog',
                    style: AppButtonStyle.outline,
                    expand: true,
                    onPressed: _busy ? null : () => _run((r) => r.updateNote(widget.hostId, n.id, reopen: true), 'Nota devuelta al backlog'),
                  ),
                ],
                const SizedBox(height: 8),
                AppButton(label: 'Eliminar', style: AppButtonStyle.danger, expand: true, onPressed: _busy ? null : () => _delete(n)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AssignSheet extends ConsumerStatefulWidget {
  const AssignSheet({super.key, required this.hostId, required this.note, required this.sessions});
  final String hostId;
  final BacklogNote note;
  final List<BoardSession> sessions;

  @override
  ConsumerState<AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends ConsumerState<AssignSheet> {
  late String? _session = widget.sessions.length == 1 ? widget.sessions.single.name : null;
  bool _inProgress = false;
  bool _busy = false;

  Future<void> _assign() async {
    final session = _session;
    if (session == null || _busy) return;
    setState(() => _busy = true);
    final String? warning;
    try {
      warning = await ref.read(boardRepositoryProvider).assignNote(widget.hostId, widget.note.id, session: session, inProgress: _inProgress);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, backlogErrorText(e, assigning: true));
      return;
    }
    if (!mounted) return;
    showToast(context, warning == null ? 'Asignada a $session' : 'Asignada a $session, pero no se le pudo avisar por el buzón');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = widget.sessions;
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
              Semantics(
                header: true,
                child: Text('Asignar a un agente', style: AppFonts.inter(size: 16, weight: FontWeight.w600)),
              ),
              const SizedBox(height: 2),
              Text(widget.note.title, style: AppText.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 14),
              if (sessions.isEmpty)
                Text('No hay agentes en marcha en este host. Lanza uno desde «Agentes» y asigna la nota después.', style: AppText.body.copyWith(color: AppColors.secondary))
              else ...[
                for (final s in sessions) ...[
                  SelectTile(
                    key: ValueKey('assign-session-${s.name}'),
                    selected: _session == s.name,
                    radio: true,
                    minHeight: 48,
                    semanticLabel: '${s.name}, ${statusLabel(s.status)}',
                    onTap: _busy ? null : () => setState(() => _session = s.name),
                    child: Row(
                      children: [
                        Expanded(child: Text(s.name, style: AppFonts.mono(size: 13.5, weight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        Text(statusLabel(s.status), style: AppFonts.inter(size: 12, color: StatusColors.of(s.status).fg)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 6),
                Text('Entra en su lista de tareas como', style: AppFonts.inter(size: 13, color: AppColors.secondary)),
                const SizedBox(height: 6),
                SegmentedControl<bool>(
                  radio: true,
                  options: const [(false, 'Pendiente'), (true, 'En curso')],
                  value: _inProgress,
                  onChanged: (v) {
                    if (!_busy) setState(() => _inProgress = v);
                  },
                ),
                const SizedBox(height: 8),
                Text('El agente recibe la nota por su buzón y la tarea queda en su plan hasta que la termine.', style: AppText.caption),
                const SizedBox(height: 14),
                AppButton(label: _busy ? 'Asignando…' : 'Asignar', expand: true, onPressed: _session == null || _busy ? null : _assign),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
