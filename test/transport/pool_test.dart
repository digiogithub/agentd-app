import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/transport/pool.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeShell implements RemoteShell {
  FakeShell(this.n);
  final int n;
  bool closed = false;

  @override
  bool get isClosed => closed;

  @override
  Future<void> close() async => closed = true;

  @override
  Future<ExecResult> exec(String command, {Duration timeout = const Duration(seconds: 30), String? stdin}) async => const ExecResult(0, '', '');

  @override
  Future<ByteChannel> openUnixSocket(String path) => throw UnimplementedError();

  @override
  Future<PtySession> pty({String? command, int cols = 80, int rows = 24, Map<String, String> env = const {}}) => throw UnimplementedError();
}

const a = HostConfig(id: 'a', name: 'A', host: 'a.local', user: 'me');

void main() {
  late int connects;
  late ConnectionPool pool;
  late List<FakeShell> made;

  setUp(() {
    connects = 0;
    made = [];
    pool = ConnectionPool((c) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final s = FakeShell(++connects);
      made.add(s);
      return s;
    });
  });

  test('reuses the open shell and shares concurrent connects', () async {
    final r = await Future.wait([pool.get(a), pool.get(a)]);
    expect(identical(r[0], r[1]), isTrue);
    expect(identical(await pool.get(a), r[0]), isTrue);
    expect(connects, 1);
    expect(pool.current('a'), r[0]);
  });

  test('reconnects when the shell closed', () async {
    final s1 = await pool.get(a);
    await s1.close();
    expect(pool.current('a'), isNull);
    final s2 = await pool.get(a);
    expect(identical(s1, s2), isFalse);
    expect(connects, 2);
  });

  test('reconnects when connection fields change, not for a saved fingerprint', () async {
    final s1 = await pool.get(a);
    expect(identical(await pool.get(a.copyWith(hostKeyFingerprint: 'SHA256:x')), s1), isTrue);
    final s2 = await pool.get(a.copyWith(port: 2222));
    expect(identical(s1, s2), isFalse);
    expect((s1 as FakeShell).closed, isTrue);
  });

  test('a failed connect is not cached', () async {
    var fail = true;
    final p = ConnectionPool((c) async {
      if (fail) throw StateError('down');
      return FakeShell(1);
    });
    await expectLater(p.get(a), throwsStateError);
    fail = false;
    expect(await p.get(a), isA<FakeShell>());
  });

  test('drop and dispose close shells', () async {
    final s1 = await pool.get(a) as FakeShell;
    await pool.drop('a');
    expect(s1.closed, isTrue);
    final s2 = await pool.get(a) as FakeShell;
    await pool.dispose();
    expect(s2.closed, isTrue);
    await expectLater(pool.get(a), throwsStateError);
  });
}
