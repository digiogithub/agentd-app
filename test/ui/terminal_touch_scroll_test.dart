import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart' show Terminal, TerminalView, MouseReportMode;

import 'package:agentd_app/src/ui/widgets/key_bar.dart';
import 'package:agentd_app/src/ui/widgets/terminal_touch_scroll.dart';

void main() {
  Future<List<String>> drag(WidgetTester tester, {required String modes, bool enabled = true, double dy = 60}) async {
    final out = <String>[];
    final terminal = Terminal(onOutput: out.add);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: TerminalTouchScroll(
            terminal: terminal,
            lineHeight: 10,
            enabled: enabled,
            child: TerminalView(terminal, readOnly: true),
          ),
        ),
      ),
    );
    terminal.write(modes);
    await tester.pump();
    await tester.dragFrom(const Offset(100, 100), Offset(0, dy));
    await tester.pump();
    return out;
  }

  testWidgets('main screen with wheel reports: a drag down sends wheel up events (SGR)', (tester) async {
    final out = await drag(tester, modes: '\x1b[?1000h\x1b[?1006h');
    final wheel = out.where((s) => s.startsWith('\x1b[<64;')).toList();
    expect(wheel, isNotEmpty);
    expect(out.where((s) => s.startsWith('\x1b[<65;')), isEmpty);
  });

  testWidgets('a drag up sends wheel down events', (tester) async {
    final out = await drag(tester, modes: '\x1b[?1000h\x1b[?1006h', dy: -60);
    expect(out.where((s) => s.startsWith('\x1b[<65;')), isNotEmpty);
    expect(out.where((s) => s.startsWith('\x1b[<64;')), isEmpty);
  });

  testWidgets('no mouse reporting: nothing is sent (the view scrolls its scrollback)', (tester) async {
    final out = await drag(tester, modes: '');
    expect(out.where((s) => s.contains('\x1b[<')), isEmpty);
  });

  testWidgets('observe mode: nothing is sent', (tester) async {
    final out = await drag(tester, modes: '\x1b[?1000h\x1b[?1006h', enabled: false);
    expect(out.where((s) => s.contains('\x1b[<6')), isEmpty);
  });

  testWidgets('alternate screen with wheel reports: handled here too, not doubled', (tester) async {
    final out = await drag(tester, modes: '\x1b[?1049h\x1b[?1000h\x1b[?1006h');
    expect(out.where((s) => s.startsWith('\x1b[<64;')), isNotEmpty);
    expect(out.where((s) => s.startsWith('\x1b[<68;') || s.startsWith('\x1b[<69;')), isEmpty);
    expect(out.where((s) => s == '\x1b[A' || s == '\x1bOA'), isEmpty);
  });

  test('wheel reports use buttons 64/65 in every encoding', () {
    expect(wheelReport(up: true, x: 0, y: 0, mode: MouseReportMode.sgr), '\x1b[<64;1;1M');
    expect(wheelReport(up: false, x: 9, y: 4, mode: MouseReportMode.sgr), '\x1b[<65;10;5M');
    expect(wheelReport(up: true, x: 0, y: 0, mode: MouseReportMode.normal), '\x1b[M`!!');
    expect(wheelReport(up: false, x: 0, y: 0, mode: MouseReportMode.urxvt), '\x1b[97;1;1M');
  });

  test('page keys map to their escape sequences', () {
    expect(String.fromCharCodes(keyBytes('pgup')!), '\x1b[5~');
    expect(String.fromCharCodes(keyBytes('pgdown')!), '\x1b[6~');
    expect(terminalKeys.map((k) => k.name), containsAll(['pgup', 'pgdown']));
  });
}
