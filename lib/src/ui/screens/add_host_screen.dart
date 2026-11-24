// Add a host by SSH (name, address, user, authentication) or by an
// agentd-relay invite link (`agentd relay invite` on the host).

import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../../data/hosts_repository.dart' show describeConnectError, pairErrorHint;
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'provision_screen.dart';

const _authOptions = [
  (AuthKind.generatedKey, 'Clave generada en este móvil', 'ed25519 en el llavero seguro; copia la pública con un toque'),
  (AuthKind.importedKey, 'Clave existente', 'Importar o usar un agente SSH'),
  (AuthKind.password, 'Contraseña', 'Solo para instalar la clave; no se guarda'),
];

class AddHostScreen extends ConsumerStatefulWidget {
  /// [relayLink] opens the relay form with this invite (a deep link).
  const AddHostScreen({super.key, this.relayLink});
  final String? relayLink;

  @override
  ConsumerState<AddHostScreen> createState() => _AddHostScreenState();
}

class _AddHostScreenState extends ConsumerState<AddHostScreen> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _link = TextEditingController();
  final _deviceName = TextEditingController(text: Platform.isIOS ? 'iPhone' : 'Android');
  AuthKind _auth = AuthKind.generatedKey;
  HostTransport _transport = HostTransport.ssh;
  RelayPairPhase? _phase;

  /// The last pairing failure (Spanish) and what to do about it; shown
  /// until the next attempt.
  String? _pairError;
  String? _pairHint;
  String? _publicKey;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final link = widget.relayLink;
    if (link != null) {
      _transport = HostTransport.relay;
      _link.text = link;
    }
    ref.read(hostsRepositoryProvider).publicKey().then((k) {
      if (mounted) setState(() => _publicKey = k);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _user, _password, _link, _deviceName]) {
      c.dispose();
    }
    super.dispose();
  }

  String _slug(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');

  Future<void> _connect() async {
    final host = _host.text.trim();
    final user = _user.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || user.isEmpty || port == null || port < 1 || port > 65535) {
      showToast(context, 'Rellena host, puerto y usuario');
      return;
    }
    final password = _password.text;
    if (_auth == AuthKind.password && password.isEmpty) {
      showToast(context, 'Escribe la contraseña para instalar la clave');
      return;
    }
    final name = _name.text.trim().isEmpty ? host : _name.text.trim();
    var config = HostConfig(id: _slug(name), name: name, host: host, port: port, user: user, auth: _auth);
    setState(() => _busy = true);
    final repo = ref.read(hostsRepositoryProvider);
    try {
      if (_auth == AuthKind.password) {
        // One password login installs the app's key; the host is then saved
        // with key authentication and the password is dropped.
        try {
          config = await repo.enrollWithPassword(config, password);
        } finally {
          _password.clear();
        }
      } else {
        await repo.save(config);
      }
      await repo.connect(config.id);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => ProvisionScreen(hostId: config.id)));
    } catch (e) {
      if (mounted) showToast(context, 'No se pudo conectar con $host: ${describeConnectError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteLink() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim() ?? '';
    if (!mounted) return;
    if (t.isEmpty) {
      showToast(context, 'El portapapeles está vacío');
      return;
    }
    if (relayLinkCandidates(t).isEmpty) {
      showToast(context, 'El portapapeles no contiene un enlace agentd://relay?…');
      return;
    }
    setState(() {
      _link.text = t;
      _pairError = null;
      _pairHint = null;
    });
  }

  /// Scans the QR of `agentd relay invite`: the text goes into the invite
  /// field, as a pasted link does.
  Future<void> _scanLink() async {
    final t = (await ref.read(qrScannerProvider)(context))?.trim() ?? '';
    if (!mounted || t.isEmpty) return;
    if (relayLinkCandidates(t).isEmpty) {
      showToast(context, 'Ese QR no es una invitación de agentd');
      return;
    }
    setState(() {
      _transport = HostTransport.relay;
      _link.text = t;
      _pairError = null;
      _pairHint = null;
    });
    // No toast: it would cover the Emparejar button the user taps next.
  }

  Future<void> _pair() async {
    // The repository finds the link in the text (a "Link:" prefix, line
    // wraps of the terminal).
    final link = _link.text.trim();
    if (relayLinkCandidates(link).isEmpty) {
      showToast(context, 'Pega el enlace agentd://relay?… de agentd relay invite');
      return;
    }
    final name = _deviceName.text.trim().isEmpty ? 'Móvil' : _deviceName.text.trim();
    setState(() {
      _busy = true;
      _phase = RelayPairPhase.connecting;
      _pairError = null;
      _pairHint = null;
    });
    try {
      final c = await ref
          .read(hostsRepositoryProvider)
          .pairRelay(
            link,
            deviceName: name,
            onPhase: (p) {
              if (mounted) setState(() => _phase = p);
            },
          );
      // The link holds a one-time secret: do not keep it around.
      _link.clear();
      if (!mounted) return;
      showToast(context, 'Emparejado con ${c.name}');
      Navigator.of(context).maybePop();
    } catch (e) {
      // Stays on screen (a toast is gone before it is read) with a retry.
      if (mounted) {
        setState(() {
          _pairError = describeConnectError(e);
          _pairHint = pairErrorHint(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _phase = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _transport == HostTransport.relay ? _relayForm() : _sshForm();

  Widget _transportToggle() => SegmentedControl<HostTransport>(
    radio: true,
    options: const [(HostTransport.ssh, 'SSH'), (HostTransport.relay, 'Invitación relay')],
    value: _transport,
    onChanged: (t) {
      if (!_busy) setState(() => _transport = t);
    },
  );

  Widget _relayForm() => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          const RouteHeader(title: 'Añadir host'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              children: [
                _transportToggle(),
                const SizedBox(height: 16),
                Text(
                  'Sin SSH ni puertos abiertos: el host y el móvil se encuentran en un relay (agentd-relay) con cifrado de extremo a extremo. En el host ejecuta agentd relay invite y escanea el QR que muestra, o pega aquí el enlace agentd://relay?…',
                  style: AppFonts.inter(size: 13.5, color: AppColors.secondary, height: 1.45),
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Enlace de invitación',
                  child: AppTextField(
                    key: const ValueKey('relay-link'),
                    controller: _link,
                    hint: 'agentd://relay?v=1&u=…',
                    mono: true,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    // Several lines: a link pasted with the terminal's line
                    // wraps keeps them, so the text after it is not glued on.
                    maxLines: 5,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AppButton(label: 'Escanear QR', style: AppButtonStyle.outline, icon: Icons.qr_code_scanner, onPressed: _busy ? null : _scanLink),
                    AppButton(label: 'Pegar del portapapeles', style: AppButtonStyle.outline, icon: Icons.content_paste, onPressed: _busy ? null : _pasteLink),
                  ],
                ),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Nombre de este dispositivo',
                  child: AppTextField(key: const ValueKey('relay-device-name'), controller: _deviceName, hint: 'Pixel de Ana', enabled: !_busy),
                ),
                const SizedBox(height: 8),
                Text(
                  'El host decide qué puede hacer este móvil: ver, operar (escribir a los agentes, aprobar; equivale a una terminal del host) o admin (también lanzar y terminar sesiones). Por relay solo hay sesiones de agentd: zellij, tmux, shells e instalación necesitan SSH.',
                  style: AppText.caption,
                ),
                if (_phase == RelayPairPhase.waitingApproval) ...[
                  const SizedBox(height: 16),
                  Container(
                    key: const ValueKey('relay-waiting-approval'),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: AppColors.waitingBg, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      children: [
                        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.waiting)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Aprueba en el host', style: AppFonts.inter(size: 14, weight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text('agentd relay invite pregunta si aceptas este dispositivo: responde y en el host.', style: AppText.caption),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_pairError != null && !_busy) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      key: const ValueKey('relay-pair-error'),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: AppColors.dangerBg, borderRadius: BorderRadius.circular(12)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline, size: 18, color: AppColors.danger),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('No se pudo emparejar', style: AppFonts.inter(size: 14, weight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(_pairError!, style: AppFonts.inter(size: 13, color: AppColors.secondary, height: 1.4)),
                                if (_pairHint != null) ...[const SizedBox(height: 6), Text(_pairHint!, style: AppText.caption)],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.divider)),
            ),
            child: AppButton(
              label: switch (_phase) {
                RelayPairPhase.connecting => 'Conectando…',
                RelayPairPhase.waitingApproval => 'Esperando aprobación…',
                null => _pairError != null ? 'Reintentar' : 'Emparejar',
              },
              height: 52,
              radius: 14,
              fontSize: 15,
              bold: true,
              expand: true,
              onPressed: _busy ? null : _pair,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sshForm() => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          const RouteHeader(title: 'Añadir host'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              children: [
                _transportToggle(),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _QuickTile(
                        icon: Icons.qr_code_scanner,
                        title: 'Escanear QR',
                        sub: 'agentd relay invite',
                        onTap: _busy ? () {} : _scanLink,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _QuickTile(
                        icon: Icons.download_outlined,
                        title: 'Importar',
                        sub: '~/.ssh/config o Tailscale',
                        onTap: () => showToast(context, 'Importar llegará pronto'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const SectionLabel('O a mano'),
                const SizedBox(height: 16),
                LabeledField(
                  label: 'Nombre',
                  child: AppTextField(controller: _name, hint: 'portatil'),
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: LabeledField(
                        label: 'Host',
                        child: AppTextField(controller: _host, hint: '192.168.1.40', mono: true, keyboardType: TextInputType.url),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LabeledField(
                        label: 'Puerto',
                        child: AppTextField(controller: _port, mono: true, keyboardType: TextInputType.number),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                LabeledField(
                  label: 'Usuario',
                  child: AppTextField(controller: _user, hint: 'jose'),
                ),
                const SizedBox(height: 16),
                Text('Autenticación', style: AppFonts.inter(size: 13, color: AppColors.secondary)),
                const SizedBox(height: 8),
                for (final (kind, label, sub) in _authOptions) ...[
                  SelectTile(
                    selected: _auth == kind,
                    radio: true,
                    semanticLabel: label,
                    onTap: () => setState(() => _auth = kind),
                    child: Row(
                      children: [
                        _RadioDot(on: _auth == kind),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label, style: AppFonts.inter(size: 14, weight: FontWeight.w500)),
                              const SizedBox(height: 2),
                              Text(sub, style: AppText.caption),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (_auth == AuthKind.generatedKey) _publicKeyBox(),
                if (_auth == AuthKind.password) ...[
                  LabeledField(
                    label: 'Contraseña',
                    child: AppTextField(controller: _password, obscure: true, hint: 'Solo para instalar la clave'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Se conecta una vez con la contraseña, añade la clave de este móvil a ~/.ssh/authorized_keys y a partir de ahí usa la clave. La contraseña no se guarda.',
                    style: AppText.caption,
                  ),
                ],
                if (_auth == AuthKind.importedKey) Text('Importar claves llegará pronto; de momento usa la clave generada.', style: AppText.caption),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.divider)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Al conectar verás la huella del host para confirmarla. Luego la app detecta agentd, zellij, tmux y los CLIs de agentes.',
                  style: AppFonts.inter(size: 12, color: AppColors.muted, height: 1.4),
                ),
                const SizedBox(height: 8),
                AppButton(
                  label: _busy ? 'Conectando…' : 'Conectar y detectar',
                  height: 52,
                  radius: 14,
                  fontSize: 15,
                  bold: true,
                  expand: true,
                  onPressed: _busy ? null : _connect,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _publicKeyBox() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.bg,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Añade esta clave a ~/.ssh/authorized_keys del host:', style: AppText.caption),
        const SizedBox(height: 8),
        SelectableText(_publicKey ?? 'Generando clave…', style: AppFonts.mono(size: 11.5, color: AppColors.secondary, height: 1.4)),
        const SizedBox(height: 10),
        AppButton(
          label: 'Copiar clave pública',
          style: AppButtonStyle.outline,
          icon: Icons.copy,
          onPressed: _publicKey == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: _publicKey!));
                  if (mounted) showToast(context, 'Clave pública copiada');
                },
        ),
      ],
    ),
  );
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({required this.icon, required this.title, required this.sub, required this.onTap});
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: '$title, $sub',
    excludeSemantics: true,
    child: Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: AppColors.accent),
                const SizedBox(height: 4),
                Text(title, style: AppFonts.inter(size: 14, weight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(sub, style: AppText.caption, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: on ? AppColors.accent : AppColors.faint, width: on ? 5 : 2),
    ),
  );
}
