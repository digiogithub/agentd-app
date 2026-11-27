// Settings: notifications, muted sessions, security, paired devices,
// appearance, voice mode.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../../platform/background.dart' show VoiceStart;
import '../providers.dart';
import '../theme.dart';
import '../widgets/chat_font_controls.dart';
import '../widgets/common.dart';
import '../widgets/dictation/dictation_providers.dart';
import 'devices_screen.dart';

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
    // Connected hosts with an agentd: the ones whose paired devices can be read.
    final agentdHosts = [
      for (final h in ref.watch(hostsProvider).value ?? const <HostStatus>[])
        if (h.state == HostState.online && h.capabilities?.agentdSocket != null) h,
    ];

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
              ? BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppColors.divider)),
                )
              : null,
          child: Row(
            children: [
              Expanded(child: Text(title, style: AppFonts.inter(size: 14.5))),
              Text(value, style: AppFonts.inter(size: 12.5, color: AppColors.muted)),
              const SizedBox(width: 10),
              Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
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
                const SectionLabel('Dispositivos'),
                const SizedBox(height: 8),
                if (agentdHosts.isEmpty)
                  Text('Conecta un host con agentd para ver y revocar los dispositivos emparejados con él.', style: AppText.caption)
                else ...[
                  group([
                    for (final (i, h) in agentdHosts.indexed)
                      KeyedSubtree(
                        key: ValueKey('devices-host-${h.config.id}'),
                        child: link(
                          h.config.name,
                          h.config.isRelay ? (h.config.canManageDevices ? 'ver y revocar' : 'este dispositivo') : 'ver y revocar',
                          () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DevicesScreen(hostId: h.config.id))),
                          divider: i < agentdHosts.length - 1,
                        ),
                      ),
                  ]),
                  const SizedBox(height: 8),
                  Text('Quién puede entrar en cada host por agentd-relay. Revocar corta el acceso hasta emparejar de nuevo.', style: AppText.caption),
                ],
                const SizedBox(height: 18),
                const SectionLabel('Dictado'),
                const SizedBox(height: 8),
                group([
                  link(
                    'Idioma del dictado',
                    ref.watch(dictationLocaleProvider).value ?? 'Automático',
                    () => _pickDictationLocale(context, ref),
                  ),
                ]),
                const SizedBox(height: 18),
                const SectionLabel('Segundo plano'),
                const SizedBox(height: 8),
                group([
                  SwitchRow(
                    key: const ValueKey('push-switch'),
                    title: 'Notificaciones push',
                    subtitle: 'Avisos del host con la app cerrada o desconectada: preguntas de los agentes y permisos que debes autorizar. Necesita agentd 0.10.0 con [push] activado en el host.',
                    value: s.pushEnabled,
                    onChanged: (v) => n.update((x) => x.copyWith(pushEnabled: v)),
                  ),
                  SwitchRow(
                    title: 'Mantener conexión en segundo plano',
                    subtitle: 'Notificación fija mientras haya un host conectado: la conexión y los avisos siguen con la app en segundo plano. Desde ella puedes desconectar.',
                    value: s.keepConnected,
                    onChanged: (v) => n.update((x) => x.copyWith(keepConnected: v)),
                  ),
                ]),
                const SizedBox(height: 18),
                const SectionLabel('Vista chat'),
                const SizedBox(height: 8),
                group([const ChatFontControls()], padding: const EdgeInsets.all(14)),
                const SizedBox(height: 18),
                const SectionLabel('Apariencia'),
                const SizedBox(height: 8),
                SegmentedControl<ThemeChoice>(
                  radio: true,
                  height: 40,
                  options: const [(ThemeChoice.dark, 'Oscuro'), (ThemeChoice.light, 'Claro'), (ThemeChoice.system, 'Sistema')],
                  value: s.theme,
                  onChanged: (t) => n.update((x) => x.copyWith(theme: t)),
                ),
                const SizedBox(height: 10),
                group([
                  link('Esquema oscuro', darkSchemeLabel(s.darkScheme), () => _pickScheme<DarkScheme>(
                    context,
                    title: 'Esquema oscuro',
                    values: DarkScheme.values,
                    current: s.darkScheme,
                    label: darkSchemeLabel,
                    palette: AppPalette.ofDark,
                    onPick: (v) => n.update((x) => x.copyWith(darkScheme: v)),
                  )),
                  link('Esquema claro', lightSchemeLabel(s.lightScheme), () => _pickScheme<LightScheme>(
                    context,
                    title: 'Esquema claro',
                    values: LightScheme.values,
                    current: s.lightScheme,
                    label: lightSchemeLabel,
                    palette: AppPalette.ofLight,
                    onPick: (v) => n.update((x) => x.copyWith(lightScheme: v)),
                  ), divider: false),
                ]),
                const SizedBox(height: 8),
                Text('"Sistema" usa el esquema oscuro o el claro según el modo del teléfono.', style: AppText.caption),
                const SizedBox(height: 18),
                const SectionLabel('Modo voz'),
                const SizedBox(height: 8),
                group([
                  Semantics(
                    container: true,
                    button: true,
                    label: 'Activar modo voz',
                    excludeSemantics: true,
                    child: InkWell(
                      key: const ValueKey('voice-start'),
                      onTap: () => _startVoice(context, ref),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 52),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.divider))),
                        child: Row(
                          children: [
                            Icon(Icons.headset_mic_outlined, size: 18, color: AppColors.secondary),
                            const SizedBox(width: 10),
                            Expanded(child: Text('Activar modo voz', style: AppFonts.inter(size: 14.5))),
                            Icon(Icons.chevron_right, size: 16, color: AppColors.muted),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SwitchRow(
                    key: const ValueKey('voice-headset-mic'),
                    title: 'Micrófono de los auriculares',
                    subtitle: 'Calidad de llamada mientras escucha. Apagado: micrófono del teléfono.',
                    value: s.voiceHeadsetMic,
                    onChanged: (v) => n.update((x) => x.copyWith(voiceHeadsetMic: v)),
                  ),
                ]),
                const SizedBox(height: 8),
                Text(
                  'Habla con tus agentes con auriculares Bluetooth. También desde el icono "agentd voz" o con '
                  '"Hey Google, abre agentd voz". Una pulsación: hablar; dos: repetir. Di "ayuda" para oír las órdenes.',
                  style: AppText.caption,
                ),
                const SizedBox(height: 18),
                const SectionLabel('Ahorro de batería'),
                const SizedBox(height: 8),
                SegmentedControl<BatterySaver>(
                  key: const ValueKey('battery-saver'),
                  radio: true,
                  height: 40,
                  options: const [(BatterySaver.low, 'Bajo'), (BatterySaver.medium, 'Medio'), (BatterySaver.high, 'Alto')],
                  value: s.batterySaver,
                  onChanged: (l) => n.update((x) => x.copyWith(batterySaver: l)),
                ),
                const SizedBox(height: 8),
                Text(batterySaverHelp(s.batterySaver), key: const ValueKey('battery-saver-help'), style: AppText.caption),
                const SizedBox(height: 18),
                Center(
                  child: Text(
                    switch (ref.watch(appVersionProvider).value) {
                      final v? when v.isNotEmpty => 'agentd-app $v',
                      _ => 'agentd-app',
                    },
                    key: const ValueKey('app-version'),
                    style: AppText.caption,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startVoice(BuildContext context, WidgetRef ref) async {
    final r = await ref.read(backgroundBridgeProvider).startVoice();
    if (r == VoiceStart.ok || !context.mounted) return;
    final text = r == VoiceStart.noBluetooth ? 'Conecta unos auriculares Bluetooth para usar el modo voz' : 'No se pudo activar el modo voz';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  /// A list of color schemes with a sample of each; picking one applies it.
  Future<void> _pickScheme<T>(
    BuildContext context, {
    required String title,
    required List<T> values,
    required T current,
    required String Function(T) label,
    required AppPalette Function(T) palette,
    required void Function(T) onPick,
  }) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: Text(title, style: AppText.cardTitle)),
            for (final v in values)
              ListTile(
                key: ValueKey('scheme-$v'),
                minTileHeight: 56,
                leading: SchemeSwatch(palette(v)),
                title: Text(label(v)),
                trailing: v == current ? Icon(Icons.check, color: AppColors.accent) : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
          ],
        ),
      ),
    );
    if (picked != null) onPick(picked);
  }

  Future<void> _pickDictationLocale(BuildContext context, WidgetRef ref) async {
    final locales = await ref.read(dictationServiceProvider).locales();
    if (!context.mounted) return;
    if (locales.isEmpty) {
      showToast(context, 'El dictado no está disponible en este dispositivo');
      return;
    }
    final current = ref.read(dictationLocaleProvider).value;
    final picked = await showModalBottomSheet<(String?,)>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => ListView(
        children: [
          ListTile(
            title: const Text('Automático'),
            subtitle: const Text('Idioma del dispositivo, o español'),
            trailing: current == null
                ? Icon(Icons.check, color: AppColors.accent)
                : null,
            onTap: () => Navigator.pop(ctx, (null,)),
          ),
          for (final l in locales)
            ListTile(
              title: Text(l.name),
              subtitle: Text(l.id),
              trailing: l.id == current
                  ? Icon(Icons.check, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(ctx, (l.id,)),
            ),
        ],
      ),
    );
    if (picked != null) {
      await ref.read(dictationLocaleProvider.notifier).choose(picked.$1);
    }
  }
}

/// What a battery saver level does, for the settings caption.
String batterySaverHelp(BatterySaver l) {
  final t = PowerTuning.of(l);
  String d(Duration x) => x.inMilliseconds < 1000
      ? '${x.inMilliseconds} ms'
      : x.inSeconds < 60
      ? (x.inMilliseconds % 1000 == 0 ? '${x.inSeconds} s' : '${(x.inMilliseconds / 1000).toStringAsFixed(1).replaceAll('.', ',')} s')
      : '${x.inMinutes} min';
  return 'Pantalla del agente cada ${d(t.viewInterval)} como mucho, Panel ${d(t.boardDelay)} tras un cambio, buzón cada ${d(t.mailPoll)}. '
      'En segundo plano, los hosts con push se desconectan a los ${d(t.suspendAfter)}: las preguntas y permisos siguen llegando por push.';
}

/// A small card painted with a palette: its background, a surface with a
/// line of text, and the accent, waiting and success colors.
class SchemeSwatch extends StatelessWidget {
  const SchemeSwatch(this.p, {super.key});
  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    Widget dot(Color c) => Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 3), decoration: BoxDecoration(color: c, shape: BoxShape.circle));
    return Container(
      width: 56,
      height: 40,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.border)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(5)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(height: 3, width: 26, color: p.text),
            Row(children: [dot(p.accent), dot(p.waiting), dot(p.success)]),
          ],
        ),
      ),
    );
  }
}
