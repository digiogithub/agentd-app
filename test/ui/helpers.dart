// Shared setup of the UI widget tests: phone-sized surface, fakes wired
// through ProviderScope overrides, no runtime font fetching.

import 'package:agentd_app/src/ui/fakes/fake_repositories.dart';
import 'package:agentd_app/src/ui/providers.dart';
import 'package:agentd_app/src/ui/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';

class Fakes {
  Fakes({Duration provisionDelay = const Duration(milliseconds: 10)})
    : hosts = FakeHostsRepository(),
      sessions = FakeSessionsRepository(),
      mail = FakeMailRepository(),
      board = FakeBoardRepository(),
      provision = FakeProvisionService(stepDelay: provisionDelay);

  final FakeHostsRepository hosts;
  final FakeSessionsRepository sessions;
  final FakeMailRepository mail;
  final FakeBoardRepository board;
  final FakeProvisionService provision;

  List<Override> get overrides => [
    hostsRepositoryProvider.overrideWithValue(hosts),
    sessionsRepositoryProvider.overrideWithValue(sessions),
    mailRepositoryProvider.overrideWithValue(mail),
    boardRepositoryProvider.overrideWithValue(board),
    provisionServiceProvider.overrideWithValue(provision),
  ];
}

void setUpUiTests() {
  GoogleFonts.config.allowRuntimeFetching = false;
}

/// Pumps [child] as the home of a themed MaterialApp on a 390-wide phone
/// (844 tall by default; long forms pass a taller [height] so lazy lists
/// build every row).
Future<Fakes> pumpUi(
  WidgetTester tester,
  Widget child, {
  Fakes? fakes,
  double height = 844,
  List<Override> extraOverrides = const [],
}) async {
  final f = fakes ?? Fakes();
  tester.view.physicalSize = Size(390, height) * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...f.overrides, ...extraOverrides],
      child: MaterialApp(theme: buildAppTheme(), home: child),
    ),
  );
  await tester.pump();
  await tester.pump();
  return f;
}

/// Lets streams and short timers run without waiting for endless spinners.
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
