// Ajustes > Dispositivos: the devices paired with a host through its relay
// (phones, desktops) and "Revocar" behind a confirmation. Over SSH every
// device is listed; over the relay an owner admin device sees them all and
// any other device only itself. Revoking this device removes the host from
// the app: it is unreachable until it is paired again.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../format.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Spanish label of a relay device scope.
String scopeLabel(RelayScope s) => switch (s) {
  RelayScope.view => 'solo ver',
  RelayScope.operate => 'operar',
  RelayScope.admin => 'admin',
};

String _platformLabel(String p) => switch (p) {
  'android' => 'Android',
  'ios' => 'iOS',
  'macos' || 'darwin' => 'macOS',
  'linux' => 'Linux',
  'windows' => 'Windows',
  _ => p,
};

/// User-facing (Spanish) text for a devices failure.
String devicesErrorText(Object e, {bool revoking = false}) {
  final f = e is DevicesException ? e.failure : DevicesFailure.unavailable;
  return switch (f) {
    DevicesFailure.forbidden => revoking ? 'Este dispositivo solo puede revocarse a sí mismo' : 'Este host no deja ver sus dispositivos desde aquí (¿agentd antiguo?)',
    DevicesFailure.notFound => 'Ese dispositivo ya no está emparejado',
    DevicesFailure.unavailable => revoking ? 'No se pudo revocar: sin conexión con el host' : 'No se pudo leer la lista: sin conexión con el host',
  };
}

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key, required this.hostId});
  final String hostId;

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  final Set<String> _busy = {};

  String _nameOf(PairedDevice d) => d.name.isEmpty ? d.id : d.name;

  Future<void> _revoke(PairedDevice d, String hostName) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(d.isThisDevice ? '¿Revocar este dispositivo?' : '¿Revocar ${_nameOf(d)}?', style: AppFonts.inter(size: 18, weight: FontWeight.w600)),
        content: Text(
          d.isThisDevice
              ? 'Esta app perderá el acceso a $hostName y el host se quitará de la app. Para volver a usarlo hay que emparejarlo de nuevo con una invitación (agentd relay invite).'
              : 'Dejará de poder conectarse a $hostName y sus conexiones abiertas se cierran. Para volver a entrar necesita una invitación nueva.',
          style: AppText.body,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(
            key: const ValueKey('device-revoke-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Revocar', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (!(ok ?? false) || !mounted) return;
    setState(() => _busy.add(d.id));
    try {
      await ref.read(devicesRepositoryProvider).revoke(widget.hostId, d.id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy.remove(d.id));
      showToast(context, devicesErrorText(e, revoking: true));
      // The list may be stale (already revoked elsewhere).
      ref.invalidate(devicesProvider(widget.hostId));
      return;
    }
    if (!mounted) return;
    if (d.isThisDevice) {
      // The host is gone from the app: nothing left to show here.
      showToast(context, 'Acceso revocado: $hostName se quitó de la app');
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _busy.remove(d.id));
    showToast(context, '${_nameOf(d)} revocado');
    ref.invalidate(devicesProvider(widget.hostId));
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(hostConfigProvider(widget.hostId));
    final hostName = config?.name ?? widget.hostId;
    final manage = config?.canManageDevices ?? true;
    final devices = ref.watch(devicesProvider(widget.hostId));
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RouteHeader(title: 'Dispositivos', subtitle: hostName),
            Expanded(
              child: devices.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(devicesErrorText(e), key: const ValueKey('devices-error'), textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppColors.muted)),
                        const SizedBox(height: 12),
                        AppButton(label: 'Reintentar', style: AppButtonStyle.outline, onPressed: () => ref.invalidate(devicesProvider(widget.hostId))),
                      ],
                    ),
                  ),
                ),
                data: (list) => ListView(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                  children: [
                    Text(
                      manage
                          ? 'Dispositivos emparejados con este host por agentd-relay. Revocar uno le cierra el acceso hasta que se empareje de nuevo.'
                          : 'Este dispositivo solo ve su propio acceso: la lista completa necesita SSH o un dispositivo propietario con permiso admin.',
                      style: AppText.caption,
                    ),
                    const SizedBox(height: 12),
                    if (list.isEmpty) Text('Ningún dispositivo emparejado. Empareja uno con agentd relay invite.', style: AppText.body.copyWith(color: AppColors.muted)),
                    for (final d in list) ...[_card(d, hostName, manage), const SizedBox(height: 10)],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(PairedDevice d, String hostName, bool manage) {
    final seen = d.online ? 'conectado' : (d.lastSeen == null ? 'sin conexiones' : 'visto ${relativeTime(d.lastSeen)}');
    final detail = [
      if (d.platform.isNotEmpty) _platformLabel(d.platform),
      seen,
      if (d.expiresAt != null) 'caduca ${shortDate(d.expiresAt!)}',
    ].join(' · ');
    return AppCard(
      key: ValueKey('device-${d.id}'),
      radius: 14,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: d.online ? AppColors.success : AppColors.faint),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_nameOf(d), style: AppFonts.inter(size: 14.5, weight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
              if (d.isThisDevice) ...[const SizedBox(width: 8), const TagChip('este dispositivo')],
            ],
          ),
          const SizedBox(height: 4),
          Text(detail, style: AppText.caption),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              TagChip(scopeLabel(d.scope)),
              if (d.guest) const TagChip('invitado'),
              for (final s in d.sessions) TagChip(s),
            ],
          ),
          if (manage || d.isThisDevice) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                key: ValueKey('device-revoke-${d.id}'),
                label: _busy.contains(d.id) ? 'Revocando…' : 'Revocar',
                style: AppButtonStyle.danger,
                radius: 10,
                fontSize: 13,
                semanticLabel: 'Revocar ${_nameOf(d)}',
                onPressed: _busy.contains(d.id) ? null : () => _revoke(d, hostName),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
