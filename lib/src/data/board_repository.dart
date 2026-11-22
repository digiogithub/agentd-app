// BoardRepository over agentd: op board per host, refreshed (debounced,
// conditional with since_digest) on the session, status, attention, mail
// and task events of its own subscription.

import 'dart:async';

import '../agentd/agentd.dart';
import '../core/contracts.dart';
import 'agentd_clients.dart';

class LiveBoardRepository implements BoardRepository {
  LiveBoardRepository({
    required this._hosts,
    required this._clients,
    this.refreshDebounce = const Duration(milliseconds: 250),
    this.retry = const Duration(seconds: 20),
  });

  final HostsRepository _hosts;
  final AgentdClients _clients;

  /// Coalescing delay of the refreshes triggered by events.
  final Duration refreshDebounce;

  /// Delay before asking again after a failed or refused board.
  final Duration retry;

  /// Event kinds (prefixes) that can change a board.
  static const eventKinds = ['session', 'status', 'attention', 'mail', 'task'];

  final Map<String, _BoardHost> _boards = {};
  final Map<String, HostStatus> _status = {};
  StreamSubscription<List<HostStatus>>? _hostsSub;
  bool _hostsKnown = false;

  _BoardHost _board(String hostId) => _boards.putIfAbsent(hostId, () => _BoardHost(this, hostId));

  @override
  Stream<HostBoard> watch(String hostId) => _board(hostId).stream();

  @override
  Future<void> answer(String hostId, int questionId, String body) async {
    final c = await _clients.forHost(hostId);
    if (c == null) throw StateError('host $hostId has no reachable agentd');
    await c.reply(questionId, body);
    _boards[hostId]?.refresh();
  }

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
  }

  void _schedule(Duration after) {
    if (!watched) return;
    _timer?.cancel();
    _timer = Timer(after, () {
      _timer = null;
      refresh();
    });
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
      if (!r.notModified || _last == null || !_last!.available) {
        if (r.notModified) {
          // The digest outlived the cached board: ask for the whole of it.
          _digest = null;
          _again = true;
        } else {
          _digest = r.digest.isEmpty ? null : r.digest;
          _emit(toHostBoard(r, hostId: hostId));
        }
      }
      // The daemon has a board, so it knows the task kinds too.
      _events ??= c.subscribe(kinds: LiveBoardRepository.eventKinds).events.listen(_on, onError: (Object _) {});
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

  void _on(AgentdEvent e) {
    switch (e) {
      case SubscribedEvent(:final reconnect):
        // The first connection follows a fresh board; a reconnection may
        // have missed events.
        if (reconnect) _schedule(repo.refreshDebounce);
      case ResyncEvent() ||
          SessionInfoEvent() ||
          SessionExitedEvent() ||
          SessionRemovedEvent() ||
          StatusChangedEvent() ||
          AttentionChangedEvent() ||
          MailEvent() ||
          TaskChangedEvent() ||
          SessionLabelsEvent():
        _schedule(repo.refreshDebounce);
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
