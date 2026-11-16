// Horizontal row of thumbnails above the composer text field.

import 'package:material_ui/material_ui.dart';

import '../../theme.dart';
import 'attachment.dart';

class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({
    super.key,
    required this.items,
    required this.onEdit,
    required this.onRemove,
    this.enabled = true,
  });

  final List<Attachment> items;
  final void Function(Attachment) onEdit;
  final void Function(Attachment) onRemove;

  /// False while uploading.
  final bool enabled;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 76,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (context, i) {
        final a = items[i];
        return SizedBox(
          key: ValueKey('attachment-${a.id}'),
          width: 64,
          height: 64,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Semantics(
                  container: true,
                  button: true,
                  label:
                      'Imagen ${i + 1}${a.edited ? ', con marcas' : ''}: marcar',
                  excludeSemantics: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: enabled ? () => onEdit(a) : null,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: a.edited
                                ? AppColors.accent
                                : AppColors.border,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Image.memory(
                          a.annotated ?? a.original,
                          fit: BoxFit.cover,
                          cacheWidth: 192,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => Center(
                            child: Icon(
                              Icons.image_outlined,
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (a.edited)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Icon(Icons.edit, size: 14, color: AppColors.accent),
                ),
              Positioned(
                right: -8,
                top: -8,
                child: Semantics(
                  container: true,
                  button: true,
                  label: 'Quitar imagen ${i + 1}',
                  excludeSemantics: true,
                  child: InkResponse(
                    onTap: enabled ? () => onRemove(a) : null,
                    radius: 22,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: AppColors.raised2,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Icon(
                            Icons.close,
                            size: 14,
                            color: AppColors.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
