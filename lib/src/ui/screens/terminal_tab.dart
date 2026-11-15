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

const terminalTheme = TerminalTheme(
  cursor: AppColors.accent,
  selection: Color(0x559DB4FF),
  foreground: AppColors.secondary,
  background: AppColors.terminalBg,
  black: Color(0xFF0D1117),
  red: Color(0xFFFF7B72),
  green: AppColors.success,
  yellow: Color(0xFFD29922),
  blue: AppColors.working,
  magenta: Color(0xFFD2A8FF),
  cyan: Color(0xFF39C5CF),
  white: AppColors.secondary,
  brightBlack: AppColors.faint,
  brightRed: AppColors.danger,
  brightGreen: AppColors.successText,
  brightYellow: AppColors.waiting,
  brightBlue: AppColors.accent,
  brightMagenta: Color(0xFFE2C5FF),
  brightCyan: Color(0xFF56D4DD),
  brightWhite: AppColors.text,
  searchHitBackground: AppColors.waitingBg,
  searchHitBackgroundCurrent: AppColors.waiting,
  searchHitForeground: AppColors.text,
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
      // A new attach starts with a full redraw: drop what the previous one drew.
      _terminal.write('\x1b[H\x1b[2J\x1b[3J');
      _sub = pty.stream
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write, onError: (Object _) => _setError('Se perdió la conexión con la terminal'));
      if (_error != null) setState(() => _error = null);
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

  // The local view size changes, the remote PTY keeps its size (the agent's
  // layout is shared with other clients).
  void _onResize(int cols, int rows, int pw, int ph) => widget.onSize?.call(cols, rows);

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
                    child: TerminalView(
                      _terminal,
                      theme: terminalTheme,
                      textStyle: TerminalStyle(fontSize: 11.5, height: 1.55, fontFamily: AppFonts.monoFamily),
                      readOnly: widget.observe,
                      keyboardAppearance: Brightness.dark,
                    ),
                  ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: const BoxDecoration(
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
                  control ? 'Control: tus teclas llegan al agente. El tamaño del PTY no cambia.' : 'Observar: solo lectura, nadie ve tus pulsaciones.',
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
