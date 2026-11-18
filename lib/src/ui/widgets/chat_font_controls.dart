// Size and font of the chat view's text: Ajustes > Vista chat and the
// session's "Texto del chat" sheet change the same saved setting.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../providers.dart';
import '../theme.dart';
import 'common.dart';

class ChatFontControls extends ConsumerWidget {
  const ChatFontControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final size = s.chatFontSize;
    void setSize(double v) => n.update(
      (x) =>
          x.copyWith(chatFontSize: v.clamp(kMinChatFontSize, kMaxChatFontSize)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Tamaño del texto', style: AppFonts.inter(size: 15)),
            ),
            RoundIconButton(
              icon: Icons.remove,
              label: 'Texto más pequeño',
              bg: AppColors.surface,
              border: AppColors.border,
              fg: AppColors.secondary,
              iconSize: 18,
              onPressed: size <= kMinChatFontSize
                  ? null
                  : () => setSize(size - 1),
            ),
            SizedBox(
              width: 64,
              child: Text(
                '${size % 1 == 0 ? size.toInt() : size} pt',
                textAlign: TextAlign.center,
                style: AppFonts.inter(size: 14),
              ),
            ),
            RoundIconButton(
              icon: Icons.add,
              label: 'Texto más grande',
              bg: AppColors.surface,
              border: AppColors.border,
              fg: AppColors.secondary,
              iconSize: 18,
              onPressed: size >= kMaxChatFontSize
                  ? null
                  : () => setSize(size + 1),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('Tipo de letra', style: AppFonts.inter(size: 15)),
        const SizedBox(height: 8),
        SegmentedControl<ChatFont>(
          radio: true,
          height: 40,
          options: [for (final f in ChatFont.values) (f, chatFontLabel(f))],
          value: s.chatFont,
          onChanged: (f) => n.update((x) => x.copyWith(chatFont: f)),
        ),
        const SizedBox(height: 12),
        Text(
          'Así se verá el texto del agente.',
          style: AppFonts.chat(
            s.chatFont,
            size: size,
            color: AppColors.secondary,
            height: 1.45,
          ),
        ),
        if (size != kDefaultChatFontSize)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setSize(kDefaultChatFontSize),
              child: Text(
                'Tamaño por defecto',
                style: AppFonts.inter(size: 13, color: AppColors.accent),
              ),
            ),
          ),
      ],
    );
  }
}

/// Bottom sheet with [ChatFontControls] (from the session's menu).
Future<void> showChatFontSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: ChatFontControls(),
        ),
      ),
    );
