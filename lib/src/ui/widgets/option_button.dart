// Numbered option of a pending question (chat question card).

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

class OptionButton extends StatelessWidget {
  const OptionButton({super.key, required this.number, required this.label, required this.selected, required this.onTap});
  final String number;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    selected: selected,
    inMutuallyExclusiveGroup: true,
    checked: selected,
    button: true,
    label: 'Opción $number: $label',
    excludeSemantics: true,
    child: Material(
      color: selected ? AppColors.waitingBg : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? AppColors.waiting : AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(7)),
                  child: Text(
                    number,
                    style: AppFonts.inter(size: 12, weight: FontWeight.w600, color: AppColors.secondary),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(label, style: AppFonts.inter(size: 14, height: 1.35))),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
