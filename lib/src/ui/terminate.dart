// Terminate a session: confirm, force close + delete, report.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/contracts.dart';
import 'providers.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Asks for confirmation, then terminates [s] through the repository.
/// Returns true when the session was terminated.
Future<bool> confirmTerminate(
  BuildContext context,
  WidgetRef ref,
  AgentSession s,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        '¿Forzar cierre y borrar ${s.name}?',
        style: AppFonts.inter(size: 18, weight: FontWeight.w600),
      ),
      content: Text(
        'Se mata el proceso y se elimina la sesión con su pantalla. No se puede deshacer.',
        style: AppFonts.inter(size: 14, color: AppColors.muted, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            'Terminar',
            style: TextStyle(
              color: AppColors.danger,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await ref.read(sessionsRepositoryProvider).terminate(s);
    if (context.mounted) showToast(context, 'Sesión terminada');
    return true;
  } catch (_) {
    if (context.mounted) showToast(context, 'No se pudo terminar la sesión');
    return false;
  }
}
