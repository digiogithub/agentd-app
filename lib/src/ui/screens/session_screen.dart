// One session: header with status, Chat / Terminal tabs.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../providers.dart';
import '../terminate.dart';
import '../theme.dart';
import '../widgets/chat_font_controls.dart';
import '../widgets/common.dart';
import 'chat_tab.dart';
import 'mailbox_screen.dart';
import 'terminal_tab.dart';

enum SessionTab { chat, terminal }

class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key, required this.session, this.initialTab});
  final AgentSession session;
  final SessionTab? initialTab;

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  late SessionTab _tab;
  bool _terminalOpened = false;
  bool _observe = false;
  String? _size;
  SessionView? _view;
  Object? _viewError;
  StreamSubscription<SessionView>? _sub;
  final _composerFocus = FocusNode();

  bool get _hasChat => widget.session.source == SessionSource.agentd;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab ?? (_hasChat ? SessionTab.chat : SessionTab.terminal);
    _terminalOpened = _tab == SessionTab.terminal;
    if (_hasChat) {
      _sub = ref
          .read(sessionsRepositoryProvider)
          .view(widget.session)
          .listen(
            (v) => setState(() {
              _view = v;
              _viewError = null;
            }),
            onError: (Object e) => setState(() => _viewError = e),
          );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _composerFocus.dispose();
    super.dispose();
  }

  AgentSession get _session {
    final fromView = _view?.session;
    if (fromView != null) return fromView;
    final live = ref.watch(sessionsProvider).value?.where((s) => s.key == widget.session.key).firstOrNull;
    return live ?? widget.session;
  }

  Future<void> _run(Future<void> Function() f, String error) async {
    try {
      await f();
    } catch (_) {
      if (mounted) showToast(context, error);
    }
  }

  Future<void> _terminate(AgentSession s) async {
    final done = await confirmTerminate(context, ref, s);
    if (done && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    final host = ref.watch(hostNamesProvider)[s.hostId] ?? '';
    final repo = ref.read(sessionsRepositoryProvider);
    final subtitle = _tab == SessionTab.terminal
        ? [if (host.isNotEmpty) host, ?_size, if (_observe) 'observando'].join(' · ')
        : [if (host.isNotEmpty) host, ?s.cwd, if (s.turn != null) 'turno ${s.turn}'].join(' · ');

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.divider)),
              ),
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
              child: Column(
                children: [
                  Row(
                    children: [
                      RoundIconButton(icon: Icons.chevron_left, label: 'Volver', onPressed: () => Navigator.of(context).maybePop()),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Semantics(
                              header: true,
                              child: Text(
                                sessionTitle(s),
                                style: AppFonts.inter(size: 16, weight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(subtitle, style: AppText.caption, overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusPill.status(s.status),
                      const SizedBox(width: 8),
                      if (_tab == SessionTab.terminal) ...[
                        _ModeToggle(observe: _observe, onTap: () => setState(() => _observe = !_observe)),
                        const SizedBox(width: 4),
                        _MoreMenu(onTerminate: () => _terminate(s)),
                      ] else
                        _MoreMenu(
                          onInterrupt: _hasChat ? () => _run(() => repo.interrupt(s), 'No se pudo interrumpir') : null,
                          onMailbox: _hasChat
                              ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MailboxScreen(hostId: s.hostId, pushed: true)))
                              : null,
                          onTerminate: () => _terminate(s),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: SegmentedControl<SessionTab>(
                      height: 36,
                      options: const [(SessionTab.chat, 'Chat'), (SessionTab.terminal, 'Terminal')],
                      value: _tab,
                      onChanged: (t) => setState(() {
                        _tab = t;
                        if (t == SessionTab.terminal) _terminalOpened = true;
                      }),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab.index,
                children: [
                  _hasChat
                      ? ChatTab(
                          session: s,
                          view: _view,
                          error: _viewError,
                          composerFocus: _composerFocus,
                          onOpenMailbox: () =>
                              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MailboxScreen(hostId: s.hostId, pushed: true))),
                        )
                      : _NoChat(source: s.source),
                  _terminalOpened
                      ? TerminalTab(
                          session: s,
                          observe: _observe,
                          onSize: (c, r) {
                            final v = '$c×$r';
                            if (v != _size) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() => _size = v) : null);
                          },
                        )
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.observe, required this.onTap});
  final bool observe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: 'Cambiar modo de control',
    value: observe ? 'Observar' : 'Control',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 44,
        child: Center(
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(observe ? 'Observar' : 'Control', style: AppFonts.inter(size: 12, weight: FontWeight.w600)),
          ),
        ),
      ),
    ),
  );
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({this.onInterrupt, this.onMailbox, required this.onTerminate});
  final VoidCallback? onInterrupt;
  final VoidCallback? onMailbox;
  final VoidCallback onTerminate;

  @override
  Widget build(BuildContext context) => RoundIconButton(
    icon: Icons.more_horiz,
    label: 'Más acciones',
    iconSize: 20,
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onInterrupt != null)
              ListTile(
                leading: Icon(Icons.stop_circle_outlined, color: AppColors.danger),
                title: Text('Interrumpir', style: AppFonts.inter(size: 15, color: AppColors.danger)),
                onTap: () {
                  Navigator.pop(ctx);
                  onInterrupt!();
                },
              ),
            if (onMailbox != null)
              ListTile(
                leading: Icon(Icons.inbox_outlined, color: AppColors.secondary),
                title: Text('Ver buzón del host', style: AppFonts.inter(size: 15)),
                onTap: () {
                  Navigator.pop(ctx);
                  onMailbox!();
                },
              ),
            ListTile(
              leading: Icon(Icons.text_fields, color: AppColors.secondary),
              title: Text('Texto del chat', style: AppFonts.inter(size: 15)),
              subtitle: Text('Tamaño y tipo de letra', style: AppText.caption),
              onTap: () {
                Navigator.pop(ctx);
                showChatFontSheet(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_forever_outlined, color: AppColors.danger),
              title: Text('Terminar', style: AppFonts.inter(size: 15, color: AppColors.danger)),
              subtitle: Text('Forzar cierre y borrar la sesión', style: AppText.caption),
              onTap: () {
                Navigator.pop(ctx);
                onTerminate();
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class _NoChat extends StatelessWidget {
  const _NoChat({required this.source});
  final SessionSource source;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        source == SessionSource.shell
            ? 'Una shell SSH no tiene vista chat: usa la terminal. Con agentd tendrías chat, aprobaciones y buzón.'
            : 'Las sesiones ${source.name} no tienen vista chat: usa la terminal. Con agentd tendrías chat, aprobaciones y buzón.',
        textAlign: TextAlign.center,
        style: AppText.body.copyWith(color: AppColors.muted),
      ),
    ),
  );
}
