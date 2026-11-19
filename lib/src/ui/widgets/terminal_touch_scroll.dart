// Finger scrolling for agent TUIs that ask for mouse wheel reports (Claude
// Code: mouse tracking on the main screen). xterm.dart turns drags into wheel
// events only on the alternate screen, and with the wrong button codes (68/69,
// which programs read as shift+wheel, instead of 64/65); on the main screen a
// drag scrolls its local scrollback, which holds nothing of the agent's
// transcript, so the finger did nothing. While the program asks for wheel
// reports this widget locks the view's own scrolling and turns vertical drags
// into wheel reports at the finger's cell, like a mouse wheel on the desktop
// client. Without mouse reporting the view keeps its behaviour (scrollback on
// the main screen, arrow keys on the alternate screen).

import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart' show Terminal, CellOffset, MouseReportMode;

class TerminalTouchScroll extends StatefulWidget {
  const TerminalTouchScroll({
    super.key,
    required this.terminal,
    required this.lineHeight,
    this.enabled = true,
    required this.child,
  });

  final Terminal terminal;

  /// Pixel height of one terminal line.
  final double lineHeight;

  /// False (observe mode) leaves every gesture to the terminal view.
  final bool enabled;
  final Widget child;

  /// Finger travel, in lines, for one wheel event (agent TUIs scroll a few
  /// lines per wheel tick).
  static const linesPerTick = 1.5;

  @override
  State<TerminalTouchScroll> createState() => _TerminalTouchScrollState();
}

class _TerminalTouchScrollState extends State<TerminalTouchScroll> {
  bool _wheel = false;
  int? _pointer;
  double _pending = 0;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onTerminal);
    _wheel = _wants();
  }

  @override
  void didUpdateWidget(TerminalTouchScroll old) {
    super.didUpdateWidget(old);
    if (old.terminal != widget.terminal) {
      old.terminal.removeListener(_onTerminal);
      widget.terminal.addListener(_onTerminal);
    }
    _wheel = _wants();
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminal);
    super.dispose();
  }

  bool _wants() => widget.enabled && widget.terminal.mouseMode.reportScroll;

  void _onTerminal() {
    final w = _wants();
    if (w != _wheel && mounted) setState(() => _wheel = w);
  }

  CellOffset _cell(Offset local) {
    final size = context.size ?? Size.zero;
    final t = widget.terminal;
    int at(double v, double extent, int cells) => extent <= 0 ? 0 : (v / extent * cells).floor().clamp(0, cells - 1);
    return CellOffset(at(local.dx, size.width, t.viewWidth), at(local.dy, size.height, t.viewHeight));
  }

  void _move(PointerMoveEvent e) {
    if (!_wheel || e.pointer != _pointer) return;
    _pending += e.delta.dy;
    final step = widget.lineHeight * TerminalTouchScroll.linesPerTick;
    if (step <= 0) return;
    final cell = _cell(e.localPosition);
    while (_pending.abs() >= step) {
      // Finger down = content follows it = earlier lines = wheel up.
      final up = _pending > 0;
      widget.terminal.onOutput?.call(wheelReport(up: up, x: cell.x, y: cell.y, mode: widget.terminal.mouseReportMode));
      _pending -= up ? step : -step;
    }
  }

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: _wheel ? behavior.copyWith(physics: const NeverScrollableScrollPhysics()) : behavior,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (_pointer != null) return;
          _pointer = e.pointer;
          _pending = 0;
        },
        onPointerMove: _move,
        onPointerUp: (e) {
          if (e.pointer == _pointer) _pointer = null;
        },
        onPointerCancel: (e) {
          if (e.pointer == _pointer) _pointer = null;
        },
        child: widget.child,
      ),
    );
  }
}

/// One mouse wheel report (xterm encoding: button 64 = up, 65 = down) at the
/// 0-based cell [x], [y] in the program's report [mode].
String wheelReport({required bool up, required int x, required int y, required MouseReportMode mode}) {
  final button = up ? 64 : 65;
  final cx = x + 1, cy = y + 1;
  switch (mode) {
    case MouseReportMode.sgr:
      return '\x1b[<$button;$cx;${cy}M';
    case MouseReportMode.urxvt:
      return '\x1b[${32 + button};$cx;${cy}M';
    case MouseReportMode.normal:
    case MouseReportMode.utf:
      String coord(int v) => (mode == MouseReportMode.normal && v > 223) || v > 2015 ? '\x00' : String.fromCharCode(32 + v);
      return '\x1b[M${String.fromCharCode(32 + button)}${coord(cx)}${coord(cy)}';
  }
}
