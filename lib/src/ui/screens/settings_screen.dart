// Settings: notifications, muted sessions, security, appearance.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _showKey(BuildContext context, WidgetRef ref) async {
    final key = await ref.read(hostsRepositoryProvider).publicKey();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Clave SSH de este móvil', style: AppText.routeTitle),
              const SizedBox(height: 10),
              SelectableText(key, style: AppFonts.mono(size: 11.5, color: AppColors.secondary, height: 1.4)),
              const SizedBox(height: 12),
              AppButton(
                label: 'Copiar clave pública',
                icon: Icons.copy,
                style: AppButtonStyle.outline,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: key));
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);

    Widget group(List<Widget> children, {EdgeInsets padding = EdgeInsets.zero}) => Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );

    Widget link(String title, String value, VoidCallback onTap, {bool divider = true}) => Semantics(
      container: true,
      button: true,
      label: '$title, $value',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: divider
              ? const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppColors.divider)),
                )
              : null,
          child: Row(
            children: [
              Expanded(child: Text(title, style: AppFonts.inter(size: 14.5))),
              Text(value, style: AppFonts.inter(size: 12.5, color: AppColors.muted)),
              const SizedBox(width: 10),
              const Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
            ],
          ),
        ),
      ),
    );

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ScreenHeader(title: 'Ajustes'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                const SectionLabel('Avisarme cuando'),
                const SizedBox(height: 8),
                group([
                  SwitchRow(
                    title: 'Un agente espera respuesta',
                    subtitle: 'Permisos, preguntas y planes',
                    value: s.notifyWaiting,
                    divider: true,
                    onChanged: (v) => n.update((x) => x.copyWith(notifyWaiting: v)),
                  ),
                  SwitchRow(
                    title: 'Termina un turno',
                    subtitle: 'Agrupado cada 30 s por sesión',
                    value: s.notifyTurnDone,
                    divider: true,
                    onChanged: (v) => n.update((x) => x.copyWith(notifyTurnDone: v)),
                  ),
                  SwitchRow(
                    title: 'Una sesión se cierra',
                    subtitle: 'Incluye el código de salida',
                    value: s.notifyExit,
                    divider: true,
                    onChanged: (v) => n.update((x) => x.copyWith(notifyExit: v)),
                  ),
                  SwitchRow(
                    title: 'Responder desde el aviso',
                    subtitle: 'Permitir, denegar o escribir sin abrir la app',
                    value: s.replyFromNotification,
                    onChanged: (v) => n.update((x) => x.copyWith(replyFromNotification: v)),
                  ),
                ]),
                const SizedBox(height: 18),
                const SectionLabel('Silenciadas'),
                const SizedBox(height: 8),
                group(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  s.muted.isEmpty
                      ? [
                          SizedBox(
                            height: 48,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text('Ninguna sesión silenciada', style: AppText.caption),
                            ),
                          ),
                        ]
                      : [
                          for (final m in s.muted)
                            ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 48),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(m.session, style: AppFonts.mono(size: 13.5, color: AppColors.text)),
                                  ),
                                  Text(m.until, style: AppText.caption),
                                  const SizedBox(width: 8),
                                  AppButton(
                                    label: 'Quitar',
                                    semanticLabel: 'Quitar silencio de ${m.session}',
                                    style: AppButtonStyle.outline,
                                    radius: 10,
                                    fontSize: 12.5,
                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                    onPressed: () => n.unmute(m.session),
                                  ),
                                ],
                              ),
                            ),
                        ],
                ),
                const SizedBox(height: 8),
                Text('El silencio se guarda en el host: vale para todos tus dispositivos.', style: AppText.caption),
                const SizedBox(height: 18),
                const SectionLabel('Seguridad'),
                const SizedBox(height: 8),
                group([
                  link('Claves SSH', '1 ed25519', () => _showKey(context, ref)),
                  link('Dispositivos y tokens', 'revocar', () => showToast(context, 'Gestión de dispositivos: pendiente')),
                  Semantics(
                    container: true,
                    toggled: s.biometricApprove,
                    button: true,
                    label: 'Pedir huella para aprobar',
                    excludeSemantics: true,
                    child: InkWell(
                      onTap: () => n.update((x) => x.copyWith(biometricApprove: !x.biometricApprove)),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 52),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            Expanded(child: Text('Pedir huella para aprobar', style: AppFonts.inter(size: 14.5))),
                            Text(
                              s.biometricApprove ? 'Activado' : 'Desactivado',
                              style: AppFonts.inter(size: 12.5, weight: FontWeight.w600, color: s.biometricApprove ? AppColors.success : AppColors.muted),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 18),
                const SectionLabel('Apariencia'),
                const SizedBox(height: 8),
                SegmentedControl<ThemeChoice>(
                  radio: true,
                  height: 40,
                  options: const [(ThemeChoice.dark, 'Oscuro'), (ThemeChoice.light, 'Claro'), (ThemeChoice.system, 'Sistema')],
                  value: s.theme,
                  onChanged: (t) {
                    n.update((x) => x.copyWith(theme: t));
                    if (t != ThemeChoice.dark) showToast(context, 'El tema claro llegará pronto; de momento la app es oscura');
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
