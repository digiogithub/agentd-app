// In-memory ByteChannel pair and a tiny fake agentd daemon for tests.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agentd_app/src/agentd/codec.dart';
import 'package:agentd_app/src/core/contracts.dart';

/// One end of an in-memory duplex pipe. With [chunkSize] every write to the
/// peer is split into chunks of that size (to exercise partial reads).
class PipeEnd implements ByteChannel {
  PipeEnd._(this._in, this._peerIn, this._done, {this.chunkSize});

  final StreamController<Uint8List> _in;
  final StreamController<Uint8List> _peerIn;
  final Completer<void> _done;
  final int? chunkSize;
  final List<Uint8List> written = [];
  bool _closed = false;

  @override
  Stream<Uint8List> get stream => _in.stream;

  @override
  void add(List<int> data) {
    if (_closed || _peerIn.isClosed) throw StateError('pipe closed');
    final b = Uint8List.fromList(data);
    written.add(b);
    final n = chunkSize;
    if (n == null || n <= 0) {
      _peerIn.add(b);
      return;
    }
    for (var i = 0; i < b.length; i += n) {
      _peerIn.add(Uint8List.sublistView(b, i, i + n > b.length ? b.length : i + n));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_in.isClosed) unawaited(_in.close());
    if (!_peerIn.isClosed) unawaited(_peerIn.close());
    if (!_done.isCompleted) _done.complete();
  }

  bool get isClosed => _closed || _peerIn.isClosed;

  @override
  Future<void> get done => _done.future;
}

/// Creates a connected pair (client end, server end).
(PipeEnd client, PipeEnd server) pipePair({int? serverChunk, int? clientChunk}) {
  final a = StreamController<Uint8List>();
  final b = StreamController<Uint8List>();
  final done = Completer<void>();
  final client = PipeEnd._(a, b, done, chunkSize: clientChunk);
  final server = PipeEnd._(b, a, done, chunkSize: serverChunk);
  return (client, server);
}

/// Server side of one fake daemon connection after its request line.
class FakeConn {
  FakeConn(this.end, this.op, this.args);
  final PipeEnd end;
  final String op;
  final Map<String, Object?> args;

  /// Bytes the client sent after the request line (attach frames...).
  final StreamController<Uint8List> after = StreamController<Uint8List>();

  void line(Object? json) => end.add(utf8.encode('${jsonEncode(json)}\n'));
  void ok([Object? data]) => line({'ok': true, 'data': ?data});
  void fail(String msg, {String? code, Object? data}) => line({'ok': false, 'error': msg, 'code': ?code, 'data': ?data});
  void bytes(List<int> b) => end.add(b);
  Future<void> close() => end.close();
}

typedef FakeHandler = FutureOr<void> Function(FakeConn c);

/// A fake daemon: every dial makes a pipe; the first request line is
/// recorded in [requests] and dispatched to [handlers] by op. A handler
/// returning normally after [FakeConn.ok]/[FakeConn.fail] closes the
/// connection unless [keepOpen] contains the op.
class FakeDaemon {
  FakeDaemon({this.serverChunk});

  final int? serverChunk;
  final Map<String, FakeHandler> handlers = {};
  final Set<String> keepOpen = {'subscribe', 'attach'};
  final List<Map<String, Object?>> requests = [];
  final List<FakeConn> conns = [];
  final List<PipeEnd> clientEnds = [];
  int dials = 0;
  Object? dialError;

  void on(String op, FakeHandler h) => handlers[op] = h;

  /// Answers [op] with `{ok: true, data}`.
  void answer(String op, Object? data) => on(op, (c) => c.ok(data));

  Map<String, Object?> lastArgs(String op) =>
      (requests.lastWhere((r) => r['op'] == op)['args'] as Map?)?.cast<String, Object?>() ?? const {};

  Future<ByteChannel> dial() async {
    dials++;
    final err = dialError;
    if (err != null) throw err;
    final (client, server) = pipePair(serverChunk: serverChunk);
    clientEnds.add(client);
    final dec = LineDecoder();
    FakeConn? conn;
    server.stream.listen(
      (chunk) async {
        if (conn != null) {
          conn!.after.add(chunk);
          return;
        }
        final lines = dec.add(chunk, limit: 1);
        if (lines.isEmpty) return;
        final req = (jsonDecode(lines.first) as Map).cast<String, Object?>();
        requests.add(req);
        final op = req['op'] as String;
        final c = conn = FakeConn(server, op, (req['args'] as Map?)?.cast<String, Object?>() ?? const {});
        conns.add(c);
        final rest = dec.takeRemainder();
        if (rest.isNotEmpty) c.after.add(rest);
        final h = handlers[op];
        if (h == null) {
          c.fail('unknown op "$op"', code: 'invalid');
          await c.close();
          return;
        }
        await h(c);
        if (!keepOpen.contains(op)) await c.close();
      },
      onDone: () {
        final c = conn;
        if (c != null && !c.after.isClosed) c.after.close();
      },
    );
    return client;
  }
}

// ---- Canned JSON shaped like the Go structs ----

Map<String, Object?> sessionInfoJson({
  String name = 'claude@webapp',
  String state = 'running',
  String? status = 'idle',
  bool attention = false,
  String preview = 'Done.',
  Map<String, String>? labels,
}) => {
  'name': name,
  'state': state,
  'pid': 4242,
  'cwd': '/home/u/src/webapp',
  'cmd': ['claude'],
  'profile': 'claude',
  'started_at': '2026-11-15T10:00:00.123456789Z',
  'last_output': '2026-11-15T10:05:00.5Z',
  'idle_ms': 1200,
  'unread': 0,
  'attached': 1,
  'cols': 160,
  'rows': 50,
  'title': '✳ Fix lint',
  'input_state': 'empty',
  'status': ?status,
  if (attention) 'attention': true,
  'revision': 7,
  'preview': preview,
  'turn': 3,
  'labels': ?labels,
};

Map<String, Object?> viewJson({String status = 'waiting', int revision = 9, String epoch = 'ep1'}) => {
  'name': 'claude@webapp',
  'epoch': epoch,
  'revision': revision,
  'status': status,
  'status_reason': 'menu',
  'attention': {'set': true, 'reason': 'waiting', 'since': '2026-11-15T10:06:00Z'},
  'title': 'Fix lint',
  'cwd': '/home/u/src/webapp',
  'first_line': 120,
  'lines': [
    {'text': '❯ fix the lint errors', 'role': 'transcript'},
    {'text': '', 'role': 'transcript'},
    {'text': '⏺ I will run the linter first.', 'role': 'transcript'},
    {'text': '⏺ Bash(npm run lint)', 'role': 'transcript'},
    {'text': '  ⎿  3 errors found', 'role': 'transcript'},
    {'text': '     src/a.ts:1', 'role': 'transcript'},
    {'text': '…', 'role': 'gap'},
    {'text': '✻ Thinking…', 'role': 'status'},
    {'text': 'Do you want to proceed?', 'role': 'dialog'},
  ],
  'input': {'text': '', 'ghost': 'Try "fix tests"', 'state': 'suggestion'},
  'options': [
    {'id': 'o1', 'label': 'Yes', 'index': 1, 'kind': 'numbered', 'selected': true, 'confidence': 0.9},
    {'id': 'o2', 'label': 'No', 'index': 2, 'kind': 'numbered', 'selected': false, 'confidence': 0.9},
  ],
  'hints': [
    {'key': 'esc', 'action': 'cancel'},
  ],
  'dialog': {'question': 'Do you want to proceed?'},
  'idle_ms': 3000,
};

Map<String, Object?> messageJson({int id = 5, String state = 'queued', String? queue}) => {
  'id': id,
  'sender': 'codex@api',
  'recipient': queue != null ? 'queue:$queue' : 'human:u',
  'subject': 'hi',
  'body': 'body text',
  'state': state,
  'attempts': 0,
  'created_at': '2026-11-15T09:00:00Z',
  'queue': ?queue,
};

Map<String, Object?> taskJson(String id, String title, {String status = 'pending', String? note}) => {
  'id': id,
  'title': title,
  'status': status,
  'note': ?note,
  'updated_at': '2026-11-22T09:00:00Z',
};

/// Answer of op board: one session with a plan and an open question, one
/// without tasks.
Map<String, Object?> boardJson({String digest = 'b1', bool question = true}) => {
  'sessions': [
    {
      'name': 'claude@webapp',
      'status': 'working',
      'attention': false,
      'turn': 3,
      'preview': 'Running the tests',
      'tasks': [
        taskJson('t1', 'Task model', status: 'done'),
        taskJson('t2', 'Persist tasks', status: 'in_progress'),
        taskJson('t3', 'Deploy', status: 'blocked', note: 'Missing credential'),
        taskJson('t4', 'Docs'),
        taskJson('t5', 'Old idea', status: 'cancelled'),
      ],
      'questions': [
        if (question)
          {
            'id': 21,
            'body': 'Schema v4 in this change?',
            'options': ['Same change', 'Separate'],
            'task': 't2',
            'created_at': '2026-11-22T09:10:00Z',
          },
      ],
    },
    {'name': 'codex@api', 'status': 'idle', 'attention': true, 'turn': 1, 'preview': 'Done.', 'tasks': <Object?>[], 'questions': <Object?>[]},
  ],
  'unread_human': 2,
  'digest': digest,
};
