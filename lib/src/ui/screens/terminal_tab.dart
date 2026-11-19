// Terminal view: the real PTY stream (agentd attach, zellij / tmux attach)
// rendered by xterm, with a key bar, a line input and Interrumpir.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalView, TerminalTheme, TerminalStyle;

import '../../core/contracts.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/key_bar.dart';
import '../widgets/terminal_touch_scroll.dart';

// The terminal stays dark in both modes: agent TUIs assume a dark background.
final _d = AppPalette.dark;
final terminalTheme = TerminalTheme(
  cursor: _d.accent,
  selection: Color(0x559DB4FF),
  foreground: _d.secondary,
  background: _d.terminalBg,
  black: Color(0xFF0D1117),
  red: Color(0xFFFF7B72),
  green: _d.success,
  yellow: Color(0xFFD29922),
  blue: _d.working,
  magenta: Color(0xFFD2A8FF),
  cyan: Color(0xFF39C5CF),
  white: _d.secondary,
  brightBlack: _d.faint,
  brightRed: _d.danger,
  brightGreen: _d.successText,
  brightYellow: _d.waiting,
  brightBlue: _d.accent,
  brightMagenta: Color(0xFFE2C5FF),
  brightCyan: Color(0xFF56D4DD),
  brightWhite: _d.text,
  searchHitBackground: _d.waitingBg,
  searchHitBackgroundCurrent: _d.waiting,
  searchHitForeground: _d.text,
);

class TerminalTab extends ConsumerStatefulWidget {
  const TerminalTab({super.key, required this.session, required this.observe, this.onSize});
  final AgentSession session;

  /// Observe mode: read-only attach, nothing typed reaches the agent.
  final bool observe;
  final void Function(int cols, int rows)? onSize;

  @override
  ConsumerState<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends ConsumerState<TerminalTab> {
  late final Terminal _terminal = Terminal(maxLines: 5000, onOutput: _onTerminalOutput, onResize: _onResize);
  final _input = TextEditingController();
  PtySession? _pty;
  StreamSubscription<String>? _sub;
  bool _ctrl = false;
  String? _error;
  int _generation = 0;
  Timer? _resizeTimer;
  (int, int)? _sent;

  static const _fontSize = 11.5;
  static const _lineHeight = 1.25;

  /// Coalesces view size changes (soft keyboard, rotation) before the PTY is
  /// resized: every resize makes the agent redraw its whole screen.
  static const resizeDelay = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didUpdateWidget(TerminalTab old) {
    super.didUpdateWidget(old);
    if (old.observe != widget.observe || old.session.key != widget.session.key) _connect();
  }

  @override
  void dispose() {
    _generation++;
    _resizeTimer?.cancel();
    _sub?.cancel();
    _pty?.close();
    _input.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final gen = ++_generation;
    final oldSub = _sub;
    final oldPty = _pty;
    _sub = null;
    _pty = null;
    unawaited(oldSub?.cancel());
    unawaited(oldPty?.close());
    try {
      final pty = await ref
          .read(sessionsRepositoryProvider)
          .terminal(widget.session, cols: _terminal.viewWidth, rows: _terminal.viewHeight, observe: widget.observe);
      if (!mounted || gen != _generation) {
        unawaited(pty.close());
        return;
      }
      _pty = pty;
      _sent = null;
      // A new attach starts with a full redraw: drop what the previous one drew.
      _terminal.write('\x1b[H\x1b[2J\x1b[3J');
      _sub = pty.stream
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write, onError: (Object _) => _setError('Se perdió la conexión con la terminal'));
      if (_error != null) setState(() => _error = null);
      // agentd attaches passive: in Control mode the view's size is sent now.
      _applySize();
    } catch (_) {
      _setError('No se pudo abrir la terminal');
    }
  }

  void _setError(String e) {
    if (mounted) setState(() => _error = e);
  }

  // Keystrokes from the TerminalView (hardware / soft keyboard).
  void _onTerminalOutput(String data) {
    if (widget.observe) return;
    _pty?.add(utf8.encode(data));
  }

  // Control mode: the PTY follows this view (the daemon gives the session the
  // size of its most recently active client and restores the profile size
  // when the last one detaches). Observe never resizes.
  void _onResize(int cols, int rows, int pw, int ph) {
    widget.onSize?.call(cols, rows);
    if (widget.observe) return;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(resizeDelay, _applySize);
  }

  void _applySize() {
    final pty = _pty;
    final size = (_terminal.viewWidth, _terminal.viewHeight);
    if (widget.observe || pty == null || size == _sent || size.$1 < 10 || size.$2 < 3) return;
    _sent = size;
    pty.resize(size.$1, size.$2);
  }

  // agentd translates abstract keys itself (cursor mode, profile submit);
  // the other sources are raw PTYs.
  bool get _raw => widget.session.source != SessionSource.agentd;

  Future<void> _keys(List<String> keys) async {
    if (_raw) {
      if (widget.observe) return;
      for (final k in keys) {
        final b = keyBytes(k);
        if (b != null) _pty?.add(b);
      }
      return;
    }
    try {
      await ref.read(sessionsRepositoryProvider).keys(widget.session, keys);
    } catch (_) {
      if (mounted) showToast(context, 'No se pudieron enviar las teclas');
    }
  }

  void _onKey(TermKey k) {
    if (k.name == 'ctrl') {
      setState(() => _ctrl = !_ctrl);
      return;
    }
    setState(() => _ctrl = false);
    _keys([k.name]);
  }

  void _submitLine(String text) {
    if (widget.observe) return;
    if (_ctrl && RegExp(r'^[a-y]$', caseSensitive: false).hasMatch(text)) {
      setState(() => _ctrl = false);
      _keys(['ctrl-${text.toLowerCase()}']);
    } else if (text.isNotEmpty) {
      _pty?.add(utf8.encode('$text\r'));
    } else {
      _keys(['enter']);
    }
    _input.clear();
  }

  Future<void> _interrupt() async {
    if (_raw) return _keys(['ctrl-c']);
    try {
      await ref.read(sessionsRepositoryProvider).interrupt(widget.session);
    } catch (_) {
      if (mounted) showToast(context, 'No se pudo interrumpir');
    }
  }

  @override
  Widget build(BuildContext context) {
    final control = !widget.observe;
    return Column(
      children: [
        Expanded(
          child: Container(
            color: AppColors.terminalBg,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, style: AppText.body.copyWith(color: AppColors.danger)),
                        const SizedBox(height: 12),
                        AppButton(label: 'Reintentar', style: AppButtonStyle.outline, onPressed: _connect),
                      ],
                    ),
                  )
                : Semantics(
                    label: 'Terminal de la sesión',
                    child: TerminalTouchScroll(
                      terminal: _terminal,
                      lineHeight: MediaQuery.textScalerOf(context).scale(_fontSize) * _lineHeight,
                      enabled: !widget.observe,
                      child: TerminalView(
                        _terminal,
                        theme: terminalTheme,
                        textStyle: TerminalStyle(fontSize: _fontSize, height: _lineHeight, fontFamily: AppFonts.monoFamily),
                        readOnly: widget.observe,
                        keyboardAppearance: Brightness.dark,
                      ),
                    ),
                  ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: AppColors.navBg,
            border: Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              KeyBar(onKey: _onKey, ctrlArmed: _ctrl, enabled: control),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('terminal-input'),
                      controller: _input,
                      enabled: control,
                      onSubmitted: _submitLine,
                      textInputAction: TextInputAction.send,
                      style: AppFonts.mono(size: 13, color: AppColors.text),
                      decoration: AppTextField.decoration(
                        hint: _ctrl ? 'ctrl + letra…' : 'Escribir en la terminal…',
                        mono: true,
                      ).copyWith(semanticCounterText: 'Escribir en la terminal'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AppButton(label: 'Interrumpir', style: AppButtonStyle.danger, fontSize: 13, onPressed: control ? _interrupt : null),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  control
                      ? 'Control: tus teclas llegan al agente y el PTY se ajusta a esta pantalla. Desliza el dedo o usa pg↑ / pg↓ para desplazarte.'
                      : 'Observar: solo lectura, nadie ve tus pulsaciones.',
                  style: AppFonts.inter(size: 11.5, color: AppColors.muted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
