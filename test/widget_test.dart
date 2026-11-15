// Smoke tests: the app shell boots on the fakes and on the real wiring
// (memory stores, no host saved, so nothing connects).

import 'package:agentd_app/main.dart' as app;
import 'package:agentd_app/src/data/data.dart';
import 'package:agentd_app/src/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('app boots on the fakes', (tester) async {
    await tester.pumpWidget(app.buildApp());
    await tester.pump();
    await tester.pump();
    expect(find.text('Agentes'), findsWidgets);
  });

  testWidgets('app boots on the real repositories', (tester) async {
    final data = AppData.create(store: MemoryHostStore(), keys: MemoryKeyStore(), hostKeys: MemoryHostKeyStore());
    await tester.pumpWidget(app.buildApp(data: data));
    await tester.pump();
    await tester.pump();
    expect(find.text('Agentes'), findsWidgets);
  });
}
