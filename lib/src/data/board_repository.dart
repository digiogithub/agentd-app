// BoardRepository over agentd: op board per host, refreshed (debounced,
// conditional with since_digest) on the session, status, attention, mail
// and task events of its own subscription. The backlog notes (op notes, its
// own digest) travel with the board and follow the note events.

import 'dart:async';

import '../agentd/agentd.dart';
import '../core/contracts.dart';
import 'agentd_clients.dart';

class LiveBoardRepository implements BoardRepository {
  LiveBoardRepository({
    required this._hosts,
    required this._clients,
    this._refreshDebounce,
    this._power,
    this.retry = const Duration(seconds: 20),
  });

  final HostsRepository _hosts;
  final AgentdClients _clients;
  final Duration? _refreshDebounce;
  final PowerControl? _power;

  /// Delay of the refreshes triggered by events: a fixed value (tests) or
  /// the battery saver level's.
  Duration get refreshDebounce => _refreshDebounce ?? (_power ?? PowerControl()).tuning.boardDelay;

  /// Delay before asking again after a failed or refused board.
  final Duration retry;

  /// Event kinds (prefixes) that can change a board.
  static const eventKinds = ['session', 'status', 'attention', 'mail', 'task'];

  /// Added to [eventKinds] once the daemon answered op notes (an older
  /// daemon refuses a subscription that names a kind it does not know).
  static const noteKind = 'note';

  final Map<String, _BoardHost> _boards = {};
  final Map<String, HostStatus> _status = {};
  StreamSubscription<List<HostStatus>>? _hostsSub;
  bool _hostsKnown = false;

  _BoardHost _board(String hostId) => _boards.putIfAbsent(hostId, () => _BoardHost(this, hostId));

  @override
  Stream<HostBoard> watch(String hostId) => _board(hostId).stream();

  @override
  Future<void> answer(String hostId, int questionId, String body, {bool notify = true}) async {
    final c = await _clients.forHost(hostId);
    if (c == null) throw StateError('host $hostId has no reachable agentd');
    await c.reply(questionId, body, notify: notify);
    _boards[hostId]?.refresh();
  }

  /// Runs a backlog op on [hostId] and refreshes its board.
  Future<T> _backlog<T>(String hostId, Future<T> Function(AgentdClient c) op) async {
    final c = await _clients.forHost(hostId);
    if (c == null) throw const BacklogException(BacklogFailure.unavailable, 'no reachable agentd');
    try {
      return await op(c);
    } on AgentdError catch (e) {
      // An agentd older than the backlog does not know the op.
      if (e.code == AgentdErrorCode.invalid && e.message.contains('unknown op')) throw BacklogException(BacklogFailure.unavailable, e.message);
      throw toBacklogException(e);
    } finally {
      _boards[hostId]?.refresh();
    }
  }

  @override
  Future<BacklogNote> addNote(String hostId, {required String title, String body = ''}) =>
      _backlog(hostId, (c) async => toBacklogNote(await c.noteAdd(title, body: body)));

  @override
  Future<BacklogNote> updateNote(String hostId, int noteId, {String? title, String? body, bool reopen = false}) =>
      _backlog(hostId, (c) async => toBacklogNote(await c.noteUpdate(noteId, title: title, body: body, reopen: reopen)));

  @override
  Future<void> removeNote(String hostId, int noteId) => _backlog(hostId, (c) => c.noteRm(noteId));

  @override
  Future<String?> assignNote(String hostId, int noteId, {required String session, bool inProgress = false}) =>
      _backlog(hostId, (c) async => (await c.noteAssign(noteId, session, inProgress: inProgress)).warning);

  void _ensureStarted() {
    _hostsSub ??= _hosts.watch().listen((list) {
      _hostsKnown = true;
      _status
        ..clear()
        ..addEntries(list.map((h) => MapEntry(h.config.id, h)));
      for (final b in _boards.values) {
        if (b.watched) b.sync();
      }
    });
  }

  void _maybeStop() {
    if (_boards.values.any((b) => b.watched)) return;
    _hostsSub?.cancel();
    _hostsSub = null;
    _hostsKnown = false;
  }

  AgentdClient? _clientOf(String hostId) {
    final h = _status[hostId];
    return h == null ? null : _clients.forStatus(h);
  }

  bool _canBacklog(String hostId) => _status[hostId]?.config.canBacklog ?? false;

  Future<void> dispose() async {
    await _hostsSub?.cancel();
    _hostsSub = null;
    for (final b in _boards.values) {
      b.stop();
    }
    _boards.clear();
  }
}

class _BoardHost {
  _BoardHost(this.repo, this.hostId);

  final LiveBoardRepository repo;
  final String hostId;
  final List<StreamController<HostBoard>> _listeners = [];
  HostBoard? _last;
  String? _digest;
  AgentdClient? _client;
  StreamSubscription<AgentdEvent>? _events;
  Timer? _timer;
  bool _running = false;
  bool _again = false;
  bool _synced = false;

  /// The backlog as last read (null: the host has none for this device).
  List<BacklogNote>? _notes;
  String? _notesDigest;

  /// The daemon refused op notes (unknown op, forbidden): not asked again
  /// until the host's client changes.
  bool _notesOff = false;

  /// Whether the running subscription includes the note events.
  bool _eventsWithNotes = false;

  bool get watched => _listeners.isNotEmpty;

  Stream<HostBoard> stream() {
    late StreamController<HostBoard> c;
    c = StreamController<HostBoard>(
      onListen: () {
        _listeners.add(c);
        if (_last != null) c.add(_last!);
        repo._ensureStarted();
        if (repo._hostsKnown) sync();
      },
      onCancel: () {
        _listeners.remove(c);
        if (!watched) stop();
        repo._maybeStop();
      },
    );
    return c.stream;
  }

  /// Follows the host's current client (null: offline or no agentd).
  void sync() {
    final c = repo._clientOf(hostId);
    if (_synced && identical(c, _client)) return;
    stop();
    _synced = true;
    _client = c;
    if (c == null) {
      _emit(HostBoard(hostId: hostId, available: false));
      return;
    }
    refresh();
  }

  void stop() {
    _events?.cancel();
    _events = null;
    _timer?.cancel();
    _timer = null;
    _client = null;
    _digest = null;
    _synced = false;
    _notes = null;
    _notesDigest = null;
    _notesOff = false;
  }

  void _schedule(Duration after) {
    if (!watched) return;
    _timer?.cancel();
    _timer = Timer(after, () {
      _timer = null;
      refresh();
    });
  }

  /// [_schedule] unless a refresh is already due: busy agents send status
  /// events all the time, and a restarted timer would never fire.
  void _scheduleOnce(Duration after) {
    if (_timer == null) _schedule(after);
  }

  /// Fetches the board now (one request at a time; a call during a request
  /// runs another one after it).
  void refresh() {
    if (_running) {
      _again = true;
      return;
    }
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    final c = _client;
    if (c == null || !watched) return;
    _running = true;
    try {
      final r = await c.board(sinceDigest: _digest);
      if (!identical(c, _client)) return;
      var board = _last != null && _last!.available ? _last : null;
      var changed = false;
      if (!r.notModified) {
        _digest = r.digest.isEmpty ? null : r.digest;
        board = toHostBoard(r, hostId: hostId);
        changed = true;
      } else if (board == null) {
        // The digest outlived the cached board: ask for the whole of it.
        _digest = null;
        _again = true;
      }
      if (await _fetchNotes(c)) changed = true;
      if (!identical(c, _client)) return;
      if (board != null && changed) _emit(board.withBacklog(_notes));
      // The daemon has a board, so it knows the task kinds too; the note
      // kind only once it answered op notes.
      final withNotes = _notes != null;
      if (_events != null && withNotes != _eventsWithNotes) {
        unawaited(_events!.cancel());
        _events = null;
      }
      if (_events == null) {
        _eventsWithNotes = withNotes;
        _events = c.subscribe(kinds: [...LiveBoardRepository.eventKinds, if (withNotes) LiveBoardRepository.noteKind]).events.listen(_on, onError: (Object _) {});
      }
    } on AgentdError {
      // A daemon older than the board, or a caller it refuses.
      if (!identical(c, _client)) return;
      _digest = null;
      _emit(HostBoard(hostId: hostId, available: false));
      _schedule(repo.retry);
    } catch (_) {
      // Transport failure: keep the last board and ask again later.
      if (!identical(c, _client)) return;
      if (_last == null) _emit(HostBoard(hostId: hostId, available: false));
      _schedule(repo.retry);
    } finally {
      _running = false;
      if (_again) {
        _again = false;
        refresh();
      }
    }
  }

  /// Reads the backlog into [_notes]; true when it changed. Its failures
  /// never take the board down: the section is hidden instead.
  Future<bool> _fetchNotes(AgentdClient c) async {
    bool set(List<BacklogNote>? notes) {
      final changed = notes != null || _notes != null;
      _notes = notes;
      if (notes == null) _notesDigest = null;
      return changed;
    }

    if (_notesOff || !repo._canBacklog(hostId)) return set(null);
    try {
      final r = await c.notes(sinceDigest: _notesDigest);
      if (!identical(c, _client)) return false;
      if (r.notModified) {
        if (_notes != null) return false;
        _notesDigest = null;
        _again = true;
        return false;
      }
      _notesDigest = r.digest.isEmpty ? null : r.digest;
      return set([for (final n in r.notes) toBacklogNote(n)]);
    } on AgentdError catch (e) {
      // not_ready (the store is unavailable) may heal; an unknown op or a
      // forbidden caller will not.
      if (!e.isNotReady) _notesOff = true;
      return set(null);
    } catch (_) {
      return false; // transport failure: keep what is shown
    }
  }

  void _on(AgentdEvent e) {
    switch (e) {
      case SubscribedEvent(:final reconnect):
        // The first connection follows a fresh board; a reconnection may
        // have missed events.
        if (reconnect) _scheduleOnce(repo.refreshDebounce);
      case ResyncEvent() ||
          SessionInfoEvent() ||
          SessionExitedEvent() ||
          SessionRemovedEvent() ||
          StatusChangedEvent() ||
          AttentionChangedEvent() ||
          MailEvent() ||
          TaskChangedEvent() ||
          NoteChangedEvent() ||
          SessionLabelsEvent():
        _scheduleOnce(repo.refreshDebounce);
      default:
        break; // heartbeat, hello, bye, disconnected...
    }
  }

  void _emit(HostBoard b) {
    _last = b;
    for (final c in [..._listeners]) {
      c.add(b);
    }
  }
}
