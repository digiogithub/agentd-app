// In-memory PTY and remote shell used by the fakes.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/contracts.dart';

/// A PTY that prints [screen] when listened to and echoes what is written
/// (CR becomes CRLF), like a line-discipline echo.
class FakePty implements PtySession {
  FakePty({this.screen = '', this.cols = 80, this.rows = 24});

  final String screen;
  int cols;
  int rows;
  final List<String> written = [];
  bool closed = false;

  late final StreamController<Uint8List> _out = StreamController<Uint8List>(
    onListen: () {
      if (screen.isNotEmpty) _out.add(Uint8List.fromList(utf8.encode(screen)));
    },
  );
  final Completer<void> _done = Completer<void>();
  final Completer<int?> _exit = Completer<int?>();

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  void add(List<int> data) {
    if (closed) return;
    final text = utf8.decode(data, allowMalformed: true);
    written.add(text);
    _out.add(Uint8List.fromList(utf8.encode(text.replaceAll('\r', '\r\n'))));
  }

  @override
  void resize(int cols, int rows) {
    this.cols = cols;
    this.rows = rows;
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(_out.close());
    if (!_done.isCompleted) _done.complete();
    if (!_exit.isCompleted) _exit.complete(null);
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<int?> get exitCode => _exit.future;
}

/// A remote shell that answers every command with success. [caps] is what
/// the fake provision service "detects" on it.
class FakeRemoteShell implements RemoteShell {
  FakeRemoteShell(this.hostId, {this.caps = const HostCapabilities()});

  final String hostId;
  final HostCapabilities caps;
  final List<String> commands = [];
  bool _closed = false;

  @override
  Future<ExecResult> exec(String command, {Duration timeout = const Duration(seconds: 30), String? stdin}) async {
    commands.add(command);
    return const ExecResult(0, '', '');
  }

  @override
  Future<PtySession> pty({String? command, int cols = 80, int rows = 24, Map<String, String> env = const {}}) async =>
      FakePty(screen: '\$ ', cols: cols, rows: rows);

  @override
  Future<ByteChannel> openUnixSocket(String path) => Future.error(UnsupportedError('fake shell has no sockets'));

  @override
  Future<void> close() async => _closed = true;

  @override
  bool get isClosed => _closed;
}
