import 'dart:async';

import 'package:agentd_app/src/ui/theme.dart';
import 'package:agentd_app/src/ui/widgets/dictation/dictation_button.dart';
import 'package:agentd_app/src/ui/widgets/dictation/dictation_providers.dart';
import 'package:agentd_app/src/ui/widgets/dictation/dictation_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';

class FakeDictation implements DictationService {
  DictationAvailability availability = DictationAvailability.available;
  List<DictationLocale> supported = const [
    DictationLocale('es_ES', 'Español'),
    DictationLocale('en_US', 'English'),
  ];
  String? deviceLocale;
  String? listenedLocale;
  void Function(String, bool)? onResult;
  void Function(double)? onLevel;
  int stops = 0, cancels = 0;
  final _status = StreamController<DictationStatus>.broadcast();
  final _errors = StreamController<DictationError>.broadcast();

  @override
  Stream<DictationStatus> get status => _status.stream;
  @override
  Stream<DictationError> get errors => _errors.stream;
  void emitError(DictationError e) => _errors.add(e);
  void emitStatus(DictationStatus s) => _status.add(s);

  @override
  Future<DictationAvailability> initialize() async => availability;
  @override
  Future<void> listen({
    String? localeId,
    required void Function(String, bool) onResult,
    void Function(double)? onSoundLevel,
  }) async {
    listenedLocale = localeId;
    this.onResult = onResult;
    onLevel = onSoundLevel;
    _status.add(DictationStatus.listening);
  }

  @override
  Future<void> stop() async => stops++;
  @override
  Future<void> cancel() async => cancels++;
  @override
  Future<List<DictationLocale>> locales() async => supported;
  @override
  Future<String?> systemLocaleId() async => deviceLocale;
}

class MemStore implements DictationLocaleStore {
  MemStore([this.value]);
  String? value;
  @override
  Future<String?> load() async => value;
  @override
  Future<void> save(String? id) async => value = id;
}

Future<void> pump(
  WidgetTester tester,
  FakeDictation fake,
  TextEditingController c, {
  bool show = true,
  MemStore? store,
}) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dictationServiceProvider.overrideWithValue(fake),
        dictationLocaleStoreProvider.overrideWithValue(store ?? MemStore()),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: show ? DictationButton(controller: c) : const SizedBox(),
        ),
      ),
    ),
  );
}

void main() {
  late FakeDictation fake;
  late TextEditingController c;
  setUp(() {
    fake = FakeDictation()..deviceLocale = 'fr_FR';
    c = TextEditingController();
  });

  testWidgets('start, partial updates, final commits', (tester) async {
    c.value = const TextEditingValue(
      text: 'ab cd',
      selection: TextSelection.collapsed(offset: 2),
    );
    await pump(tester, fake, c);
    expect(find.bySemanticsLabel('Dictar'), findsOneWidget);
    await tester.tap(find.byType(DictationButton));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Detener dictado'), findsOneWidget);
    expect(fake.listenedLocale, 'es_ES');

    fake.onResult!('hel', false);
    expect(c.text, 'ab hel cd');
    fake.onResult!('hello', false);
    expect(c.text, 'ab hello cd');
    fake.onLevel!(0.8);
    await tester.pump();
    expect(find.byKey(const ValueKey('dictation-ring')), findsOneWidget);

    fake.onResult!('hello world', true);
    await tester.pump();
    expect(c.text, 'ab hello world cd');
    expect(find.bySemanticsLabel('Dictar'), findsOneWidget);
    // late results after the final are ignored
    fake.onResult!('zzz', false);
    expect(c.text, 'ab hello world cd');
  });

  testWidgets('tap again stops and keeps what was heard', (tester) async {
    await pump(tester, fake, c);
    await tester.tap(find.byType(DictationButton));
    await tester.pumpAndSettle();
    fake.onResult!('hola', false);
    await tester.tap(find.byType(DictationButton));
    await tester.pump();
    expect(fake.stops, 1);
    fake.onResult!('hola mundo', true); // last result after stop
    await tester.pump();
    expect(c.text, 'hola mundo');
    expect(find.bySemanticsLabel('Dictar'), findsOneWidget);
  });

  testWidgets('stop without a final result ends by itself', (tester) async {
    await pump(tester, fake, c);
    await tester.tap(find.byType(DictationButton));
    await tester.pumpAndSettle();
    fake.onResult!('hola', false);
    await tester.tap(find.byType(DictationButton));
    await tester.pump(const Duration(seconds: 3));
    expect(c.text, 'hola');
    expect(find.bySemanticsLabel('Dictar'), findsOneWidget);
  });

  testWidgets('long press cancels and removes the partial', (tester) async {
    c.value = const TextEditingValue(
      text: 'ab',
      selection: TextSelection.collapsed(offset: 2),
    );
    await pump(tester, fake, c);
    await tester.tap(find.byType(DictationButton));
    await tester.pumpAndSettle();
    fake.onResult!('hola', false);
    expect(c.text, 'ab hola');
    await tester.longPress(find.byType(DictationButton));
    await tester.pump();
    expect(fake.cancels, 1);
    expect(c.text, 'ab');
    expect(find.bySemanticsLabel('Dictar'), findsOneWidget);
  });

  testWidgets('permission denied shows a toast and does not listen', (
    tester,
  ) async {
    fake.availability = DictationAvailability.permissionDenied;
    await pump(tester, fake, c);
    await tester.tap(find.byType(DictationButton));
    await tester.pumpAndSettle();
    expect(find.text('Permite el micrófono para dictar'), findsOneWidget);
    expect(fake.onResult, isNull);
  });

  testWidgets('no recognizer shows a toast', (tester) async {
    fake.availability = DictationAvailability.unavailable;
    await pump(tester, fake, c);
    await tester.tap(find.byType(DictationButton));
    await tester.pumpAndSettle();
    expect(
      find.text('El dictado no está disponible en este dispositivo'),
      findsOneWidget,
    );
  });

  testWidgets('a recognizer error stops and shows a toast', (tester) async {
    await pump(tester, fake, c);
    await tester.tap(find.byType(DictationButton));
    await tester.pumpAndSettle();
    fake.emitError(DictationError.other);
    await tester.pumpAndSettle();
    expect(find.textContaining('No se pudo dictar'), findsOneWidget);
    expect(find.bySemanticsLabel('Dictar'), findsOneWidget);
  });

  Future<String?> localeUsed(
    WidgetTester tester,
    FakeDictation f, {
    String? saved,
  }) async {
    await pump(tester, f, c, store: MemStore(saved));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DictationButton));
    await tester.pumpAndSettle();
    return f.listenedLocale;
  }

  testWidgets('device locale is used when supported', (tester) async {
    expect(await localeUsed(tester, fake..deviceLocale = 'en-US'), 'en_US');
  });

  testWidgets('saved locale wins over the device one', (tester) async {
    expect(
      await localeUsed(tester, fake..deviceLocale = 'fr_FR', saved: 'en_US'),
      'en_US',
    );
  });

  testWidgets('falls back to es_ES', (tester) async {
    expect(await localeUsed(tester, fake..deviceLocale = 'fr_FR'), 'es_ES');
  });

  testWidgets('disposing while listening cancels', (tester) async {
    await pump(tester, fake, c);
    await tester.tap(find.byType(DictationButton));
    await tester.pumpAndSettle();
    await pump(tester, fake, c, show: false);
    expect(fake.cancels, 1);
  });

  test('pickDictationLocale', () {
    const l = [DictationLocale('es_ES', 'es'), DictationLocale('en_US', 'en')];
    expect(
      pickDictationLocale(saved: 'en-US', device: 'es_ES', supported: l),
      'en_US',
    );
    expect(pickDictationLocale(device: 'en_us', supported: l), 'en_US');
    expect(pickDictationLocale(device: 'de_DE', supported: l), 'es_ES');
    expect(
      pickDictationLocale(
        device: 'de_DE',
        supported: const [DictationLocale('en_US', 'en')],
      ),
      'en_US',
    );
    expect(pickDictationLocale(supported: const []), 'es_ES');
  });
}
