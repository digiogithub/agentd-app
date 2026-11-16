// Session cards of the Agents inbox: approval card (permission), question
// card and the compact row used for working and finished sessions.

import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../theme.dart';
import 'common.dart';

String _subtitle(AgentSession s, String hostName) => [
  if (hostName.isNotEmpty) hostName,
  sourceLabel(s.source),
  if (s.source == SessionSource.agentd && s.updatedAt != null) relativeTime(s.updatedAt),
  if (s.source != SessionSource.agentd && s.detail != null) s.detail!,
].join(' · ');

/// Waiting on a permission: shows the command and Permitir / Denegar.
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.session,
    required this.hostName,
    required this.onAllow,
    required this.onDeny,
    required this.onOpen,
    this.busy = false,
  });
  final AgentSession session;
  final String hostName;
  final VoidCallback? onAllow;
  final VoidCallback? onDeny;
  final VoidCallback onOpen;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = session.pending!;
    return AppCard(
      borderColor: AppColors.waitingBorder,
      semanticLabel: '${sessionTitle(session)}: pide permiso',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHead(session: session, subtitle: _subtitle(session, hostName), pill: 'Permiso', avatarBg: AppColors.waitingBg, avatarFg: AppColors.waiting),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(10)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(pendingSubject(p), style: AppFonts.mono(size: 12.5, color: AppColors.secondary, height: 1.5)),
                if (p.detail != null && p.question.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(p.question, style: AppText.caption),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: AppButton(label: 'Permitir', style: AppButtonStyle.light, onPressed: busy ? null : onAllow, expand: true),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppButton(label: 'Denegar', style: AppButtonStyle.outline, onPressed: busy ? null : onDeny, expand: true),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 44,
                height: 44,
                child: Semantics(
                  container: true,
                  button: true,
                  label: 'Abrir sesión',
                  excludeSemantics: true,
                  child: Material(
                    color: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: AppColors.border),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: onOpen,
                      child: Icon(Icons.chevron_right, size: 20, color: AppColors.text),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Waiting on a question with options: tap to answer in the session.
class QuestionCard extends StatelessWidget {
  const QuestionCard({super.key, required this.session, required this.hostName, required this.onOpen});
  final AgentSession session;
  final String hostName;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = session.pending;
    final n = p?.options.length ?? 0;
    return AppCard(
      onTap: onOpen,
      semanticLabel: '${sessionTitle(session)}: ${p?.kind == PendingKind.plan ? 'plan' : 'pregunta'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CardHead(
            session: session,
            subtitle: _subtitle(session, hostName),
            pill: p == null ? 'Pregunta' : pendingLabel(p),
            avatarBg: AppColors.accentBg,
            avatarFg: AppColors.accent,
          ),
          const SizedBox(height: 8),
          InlineCodeText(
            p?.question ?? session.preview ?? 'Esperando una respuesta',
            style: AppFonts.inter(size: 14, color: AppColors.secondary, height: 1.45),
            codeSize: 13,
          ),
          const SizedBox(height: 8),
          Text(n > 0 ? '${plural(n, 'opción', 'opciones')} · toca para responder' : 'Toca para responder', style: AppText.caption),
        ],
      ),
    );
  }
}

class _CardHead extends StatelessWidget {
  const _CardHead({required this.session, required this.subtitle, required this.pill, required this.avatarBg, required this.avatarFg});
  final AgentSession session;
  final String subtitle;
  final String pill;
  final Color avatarBg;
  final Color avatarFg;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Avatar(letter: avatarLetter(session), bg: avatarBg, fg: avatarFg),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(sessionTitle(session), style: AppText.cardTitle, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(subtitle, style: AppText.caption, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
      const SizedBox(width: 8),
      StatusPill(pill, bg: AppColors.waiting, fg: AppColors.onWaiting),
    ],
  );
}

/// Compact row: working sessions (blue) and finished ones (neutral).
class SessionRow extends StatelessWidget {
  const SessionRow({super.key, required this.session, required this.hostName, required this.onOpen});
  final AgentSession session;
  final String hostName;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final working = s.status == AgentStatus.working || s.status == AgentStatus.starting;
    final mux = s.source != SessionSource.agentd;

    final Widget avatar = mux
        ? Avatar(icon: Icons.space_dashboard_outlined, bg: AppColors.raised, fg: AppColors.secondary)
        : Avatar(letter: avatarLetter(s), bg: working ? AppColors.workingBg : AppColors.raised, fg: working ? AppColors.working : AppColors.muted);

    final String sub;
    final bool monoSub;
    if (mux) {
      sub = [if (hostName.isNotEmpty) hostName, 'SSH', ?s.detail].join(' · ');
      monoSub = false;
    } else if (working) {
      sub = s.status == AgentStatus.starting ? 'Arrancando…' : (s.preview ?? 'Trabajando…');
      monoSub = s.status == AgentStatus.working && s.preview != null;
    } else if (s.status == AgentStatus.exited) {
      sub = 'Sesión terminada${s.preview != null ? ' · «${s.preview}»' : ''}';
      monoSub = false;
    } else {
      sub = s.preview != null ? 'Turno terminado · «${s.preview}»' : 'Turno terminado';
      monoSub = false;
    }

    Widget? trailing;
    if (working) {
      trailing = Text(mux ? 'activo' : shortDuration(s.updatedAt), style: AppFonts.inter(size: 12, color: AppColors.working));
    } else if (s.attention) {
      trailing = Semantics(
        label: 'Sin ver',
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(4)),
        ),
      );
    }

    return AppCard(
      onTap: onOpen,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      semanticLabel: '${sessionTitle(s)}: ${statusLabel(s.status)}',
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sessionTitle(s), style: AppText.cardTitle, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoSub ? AppFonts.mono(size: 12, color: AppColors.muted) : AppFonts.inter(size: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing],
        ],
      ),
    );
  }
}
