// Trust-on-first-use confirmation of a host key.

import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../theme.dart';

/// Shows the fingerprint of a new host key and asks whether to trust it.
/// Dismissing the dialog refuses the key.
Future<bool> showHostKeyDialog(BuildContext context, HostKeyPrompt p) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => HostKeyDialog(prompt: p),
  );
  return ok ?? false;
}

class HostKeyDialog extends StatelessWidget {
  const HostKeyDialog({super.key, required this.prompt});
  final HostKeyPrompt prompt;

  @override
  Widget build(BuildContext context) {
    final h = prompt.host;
    final address = '${h.user}@${h.host}${h.port == 22 ? '' : ':${h.port}'}';
    return AlertDialog(
      title: Text('¿Confiar en ${h.name}?', style: AppFonts.inter(size: 18, weight: FontWeight.w600)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Es la primera conexión con $address. Comprueba que la huella coincide con la del host (ssh-keygen -lf /etc/ssh/ssh_host_${_short(prompt.keyType)}_key.pub).',
            style: AppFonts.inter(size: 13.5, color: AppColors.secondary, height: 1.4),
          ),
          const SizedBox(height: 12),
          Text(prompt.keyType, style: AppText.caption),
          const SizedBox(height: 4),
          SelectableText(prompt.fingerprint, style: AppFonts.mono(size: 12, color: AppColors.text, height: 1.4)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confiar')),
      ],
    );
  }
}

String _short(String keyType) {
  if (keyType.contains('ed25519')) return 'ed25519';
  if (keyType.contains('ecdsa')) return 'ecdsa';
  if (keyType.contains('rsa')) return 'rsa';
  return '*';
}
