import 'dart:async';
import 'dart:typed_data';

import 'package:agentd_app/src/core/contracts.dart';

/// A [RemoteShell] that records commands and answers with canned results.
/// Rules are matched in order; the first whose pattern is contained in the
/// command (String) or matches it (RegExp) wins. Unmatched commands get
/// [fallback].
class FakeRemoteShell implements RemoteShell {
  FakeRemoteShell({this.fallback = const ExecResult(0, '', '')});

  final ExecResult fallback;
  final List<(Pattern, ExecResult Function(String))> _rules = [];
  final List<String> commands = [];
  final List<({String? command, int cols, int rows})> ptys = [];
  bool _closed = false;
  final Map<String, ({Uint8List data, int mode})> writes = {};

  void on(Pattern pattern, ExecResult result) => _rules.add((pattern, (_) => result));
  void onThrow(Pattern pattern, Object error) => _rules.add((pattern, (_) => throw error));

  @override
  Future<ExecResult> exec(String command, {Duration timeout = const Duration(seconds: 30), String? stdin}) async {
    commands.add(command);
    for (final (p, f) in _rules) {
      final hit = p is RegExp ? p.hasMatch(command) : command.contains(p);
      if (hit) return f(command);
    }
    return fallback;
  }

  @override
  Future<PtySession> pty({String? command, int cols = 80, int rows = 24, Map<String, String> env = const {}}) async {
    ptys.add((command: command, cols: cols, rows: rows));
    return FakePty();
  }

  @override
  Future<ByteChannel> openUnixSocket(String path) => throw UnimplementedError();

  @override
  Future<void> writeFile(
    String path,
    Uint8List data, {
    int mode = 0x180,
  }) async {
    writes[path] = (data: data, mode: mode);
  }

  @override
  Future<void> close() async => _closed = true;

  @override
  bool get isClosed => _closed;
}

class FakePty implements PtySession {
  final _c = StreamController<Uint8List>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stream => _c.stream;

  @override
  void add(List<int> data) {}

  @override
  Future<void> close() async {
    await _c.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<int?> get exitCode async => 0;

  @override
  void resize(int cols, int rows) {}
}
