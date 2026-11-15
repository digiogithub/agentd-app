// A plain login shell over SSH (SessionSource.shell): one remote PTY that
// several terminal views can attach to and detach from while it runs.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../core/contracts.dart';

class ShellSession {
  ShellSession(this.session, this._pty, {this.replayBytes = 256 * 1024}) {
    _sub = _pty.stream.listen(_onData, onDone: _finish, onError: (Object _) => _finish());
    _pty.done.then((_) => _finish(), onError: (Object _) => _finish());
  }

  AgentSession session;
  final PtySession _pty;

  /// Output kept to repaint a newly attached view.
  final int replayBytes;

  final Queue<Uint8List> _buf = Queue<Uint8List>();
  int _bufLen = 0;
  final Set<_ShellView> _views = {};
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<Uint8List> _sub;

  /// Completes when the shell exits or the connection closes.
  Future<void> get done => _done.future;
  bool get isDone => _done.isCompleted;

  void _onData(Uint8List b) {
    _buf.add(b);
    _bufLen += b.length;
    while (_bufLen > replayBytes && _buf.length > 1) {
      _bufLen -= _buf.removeFirst().length;
    }
    for (final v in [..._views]) {
      v._out.add(b);
    }
  }

  void _finish() {
    if (_done.isCompleted) return;
    _done.complete();
    _sub.cancel();
    for (final v in [..._views]) {
      v._end();
    }
  }

  /// A new view: the recent output first, then the live stream. Closing the
  /// view detaches it; the shell keeps running.
  PtySession attach({int? cols, int? rows}) {
    final v = _ShellView(this);
    if (!isDone) _views.add(v);
    if (cols != null && rows != null && cols > 0 && rows > 0) _pty.resize(cols, rows);
    return v;
  }

  /// Ends the shell.
  Future<void> close() async {
    await _pty.close();
    _finish();
  }
}

class _ShellView implements PtySession {
  _ShellView(this._s) {
    _out = StreamController<Uint8List>(
      onListen: () {
        for (final b in _s._buf) {
          _out.add(b);
        }
        if (_s.isDone) _end();
      },
    );
  }

  final ShellSession _s;
  late final StreamController<Uint8List> _out;
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  void _end() {
    _s._views.remove(this);
    if (!_out.isClosed) unawaited(_out.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  void add(List<int> data) {
    if (_closed || _s.isDone) return;
    _s._pty.add(data);
  }

  @override
  void resize(int cols, int rows) {
    if (_closed || _s.isDone || cols <= 0 || rows <= 0) return;
    _s._pty.resize(cols, rows);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _end();
  }

  @override
  Future<void> get done => _done.future;

  @override
  Future<int?> get exitCode => _s._pty.exitCode;
}
