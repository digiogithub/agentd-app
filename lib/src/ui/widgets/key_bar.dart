// Key bar of the terminal view: esc tab ctrl arrows enter.

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

class TermKey {
  const TermKey(this.label, this.semantic, this.name);
  final String label; // shown on the key
  final String semantic; // Spanish accessibility label
  final String name; // abstract key name sent to SessionsRepository.keys ('ctrl' is a modifier)
}

const terminalKeys = [
  TermKey('esc', 'Escape', 'esc'),
  TermKey('tab', 'Tabulador', 'tab'),
  TermKey('ctrl', 'Control', 'ctrl'),
  TermKey('↑', 'Arriba', 'up'),
  TermKey('↓', 'Abajo', 'down'),
  TermKey('←', 'Izquierda', 'left'),
  TermKey('→', 'Derecha', 'right'),
  TermKey('⏎', 'Intro', 'enter'),
];

class KeyBar extends StatelessWidget {
  const KeyBar({super.key, required this.onKey, this.ctrlArmed = false, this.enabled = true, this.keys = terminalKeys});
  final ValueChanged<TermKey> onKey;
  final bool ctrlArmed;
  final bool enabled;
  final List<TermKey> keys;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final (i, k) in keys.indexed) ...[if (i > 0) const SizedBox(width: 6), Expanded(child: _key(k))],
    ],
  );

  Widget _key(TermKey k) {
    final armed = k.name == 'ctrl' && ctrlArmed;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      toggled: k.name == 'ctrl' ? armed : null,
      label: k.semantic,
      excludeSemantics: true,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: SizedBox(
          height: 44,
          child: Material(
            color: armed ? AppColors.accentBg : AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: armed ? AppColors.accent : AppColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? () => onKey(k) : null,
              child: Center(
                child: Text(
                  k.label,
                  style: AppFonts.mono(size: 12.5, weight: FontWeight.w500, color: armed ? AppColors.accentLight : AppColors.text),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bytes of an abstract key name (agentd act names) for a raw PTY: used for
/// zellij / tmux / SSH shell sessions, where no daemon translates the keys.
/// Unknown names give null.
List<int>? keyBytes(String name) {
  const fixed = <String, String>{
    'enter': '\r',
    'esc': '\x1b',
    'tab': '\t',
    'shift-tab': '\x1b[Z',
    'up': '\x1b[A',
    'down': '\x1b[B',
    'right': '\x1b[C',
    'left': '\x1b[D',
    'backspace': '\x7f',
    'space': ' ',
  };
  final f = fixed[name];
  if (f != null) return f.codeUnits;
  final ctrl = RegExp(r'^ctrl-([a-z])$').firstMatch(name);
  if (ctrl != null) return [ctrl.group(1)!.codeUnitAt(0) - 0x60];
  return null;
}
