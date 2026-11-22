// Building blocks shared by the Panel, its sheets and the agent's task view.

import 'package:material_ui/material_ui.dart';

import '../panel_model.dart';
import '../theme.dart';

/// Thin progress bar of an agent's plan.
class TaskProgressBar extends StatelessWidget {
  const TaskProgressBar(this.value, {super.key, this.height = 4});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        color: AppColors.raised2,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: value.clamp(0, 1).toDouble(),
          child: Container(color: AppColors.working),
        ),
      ),
    ),
  );
}

/// "Enviar a": Buzón or Prompt. [promptEnabled] is false when the agent's
/// terminal can not be written (session gone).
class SendTargetControl extends StatelessWidget {
  const SendTargetControl({super.key, required this.value, required this.onChanged, this.promptEnabled = true});
  final SendTarget value;
  final ValueChanged<SendTarget> onChanged;
  final bool promptEnabled;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Destino',
    child: Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          for (final (t, label) in const [(SendTarget.mailbox, 'Buzón'), (SendTarget.prompt, 'Prompt')])
            Expanded(
              child: Semantics(
                button: true,
                selected: value == t,
                enabled: t == SendTarget.mailbox || promptEnabled,
                child: Material(
                  key: ValueKey('target-${t.name}'),
                  color: value == t ? AppColors.raised : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: t == SendTarget.prompt && !promptEnabled ? null : () => onChanged(t),
                    child: SizedBox(
                      height: 44,
                      child: Center(
                        child: Text(
                          label,
                          style: AppFonts.inter(
                            size: 14,
                            weight: value == t ? FontWeight.w600 : FontWeight.w400,
                            color: value == t ? AppColors.text : (t == SendTarget.prompt && !promptEnabled ? AppColors.faint : AppColors.muted),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// The drag handle of a bottom sheet.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2)),
      ),
    ),
  );
}
