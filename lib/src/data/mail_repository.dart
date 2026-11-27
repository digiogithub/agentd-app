// MailRepository over agentd: the user's inbox, a peek at every session's
// mailbox (op inbox `as`, no state change) and the work queues, polled while
// watched (conditional with since_digest).

import 'dart:async';

import '../agentd/agentd.dart';
import '../core/contracts.dart';
import 'agentd_clients.dart';

class AgentdMailRepository implements MailRepository {
  AgentdMailRepository({required this._clients, this._poll, this._power});

  final AgentdClients _clients;
  final Duration? _poll;
  final PowerControl? _power;

  /// Poll interval while a screen shows the mailbox: a fixed value (tests)
  /// or the battery saver level's.
  Duration get poll => _poll ?? (_power ?? PowerControl()).tuning.mailPoll;

  final Map<String, _MailPoller> _pollers = {};

  _MailPoller _poller(String hostId) => _pollers.putIfAbsent(hostId, () => _MailPoller(this, hostId));

  @override
  Stream<List<MailMessage>> inbox(String hostId) => _poller(hostId).inbox();

  @override
  Stream<List<WorkQueue>> queues(String hostId) => _poller(hostId).queues();

  @override
  Future<void> send(String hostId, {required String to, required String body, String subject = ''}) async {
    final c = await _clients.forHost(hostId);
    if (c == null) throw StateError('host $hostId has no reachable agentd');
    await c.send(to: to, body: body, subject: subject);
    _pollers[hostId]?.kick();
  }
}

class _MailPoller {
  _MailPoller(this.repo, this.hostId);

  final AgentdMailRepository repo;
  final String hostId;
  final List<StreamController<List<MailMessage>>> _inbox = [];
  final List<StreamController<List<WorkQueue>>> _queues = [];
  List<MailMessage>? _lastMail;
  List<WorkQueue>? _lastQueues;
  final Map<String, (String, List<AgentdMessage>)> _mailboxes = {}; // as → (digest, messages)
  final Map<String, (String, List<AgentdMessage>)> _queueItems = {};
  Timer? _timer;
  bool _running = false;

  Stream<List<MailMessage>> inbox() {
    late StreamController<List<MailMessage>> c;
    c = StreamController<List<MailMessage>>(
      onListen: () {
        _inbox.add(c);
        if (_lastMail != null) c.add(_lastMail!);
        _start();
      },
      onCancel: () {
        _inbox.remove(c);
        _maybeStop();
      },
    );
    return c.stream;
  }

  Stream<List<WorkQueue>> queues() {
    late StreamController<List<WorkQueue>> c;
    c = StreamController<List<WorkQueue>>(
      onListen: () {
        _queues.add(c);
        if (_lastQueues != null) c.add(_lastQueues!);
        _start();
      },
      onCancel: () {
        _queues.remove(c);
        _maybeStop();
      },
    );
    return c.stream;
  }

  void _start() {
    if (_timer == null) _tick();
    kick();
  }

  /// One poll every [AgentdMailRepository.poll], read again each time (the
  /// battery saver level can change).
  void _tick() {
    _timer = Timer(repo.poll, () {
      kick();
      _tick();
    });
  }

  void _maybeStop() {
    if (_inbox.isNotEmpty || _queues.isNotEmpty) return;
    _timer?.cancel();
    _timer = null;
  }

  void kick() {
    if (_running) return;
    unawaited(_poll());
  }

  /// One mailbox, conditional on its last digest.
  Future<List<AgentdMessage>> _mailbox(AgentdClient c, String? as) async {
    final k = as ?? '';
    final prev = _mailboxes[k];
    final r = await c.inbox(as: as, all: true, sinceDigest: prev?.$1);
    if (r.notModified && prev != null) return prev.$2;
    _mailboxes[k] = (r.digest ?? '', r.messages);
    return r.messages;
  }

  Future<void> _poll() async {
    _running = true;
    try {
      final c = await repo._clients.forHost(hostId);
      if (c == null) {
        _emit(const [], const []);
        return;
      }
      // Work queues are not exposed over the relay (forbidden): none.
      final queueList = await _unlessForbidden(() async => (await c.queue()).queues) ?? const [];
      final queues = [for (final q in queueList) toWorkQueue(q)];
      if (_inbox.isEmpty) {
        _emit(null, queues);
        return;
      }
      final byId = <int, AgentdMessage>{};
      // A guest device has no mailbox at all.
      final own = await _unlessForbidden(() => _mailbox(c, null));
      if (own == null) {
        _emit(const [], queues);
        return;
      }
      for (final m in own) {
        byId[m.id] = m;
      }
      // Mail between agents: peek at every session's mailbox.
      final sessions = await c.ls();
      for (final s in sessions) {
        try {
          for (final m in await _mailbox(c, s.name)) {
            byId[m.id] = m;
          }
        } on AgentdError {
          // Removed meanwhile, or not visible to this relay device.
        }
      }
      _mailboxes.removeWhere((k, _) => k.isNotEmpty && !sessions.any((s) => s.name == k));
      for (final q in queueList) {
        final prev = _queueItems[q.name];
        final r = await c.queue(name: q.name, bodies: true, sinceDigest: prev?.$1);
        final items = r.notModified && prev != null ? prev.$2 : r.items;
        _queueItems[q.name] = (r.digest ?? '', items);
        for (final m in items) {
          byId[m.id] = m;
        }
      }
      _queueItems.removeWhere((k, _) => !queueList.any((q) => q.name == k));
      final mail = [for (final m in byId.values) toMailMessage(m)]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      _emit(mail, queues);
    } catch (e) {
      // Keep the last lists; report only when nothing was ever shown.
      if (_lastMail == null) {
        for (final c in [..._inbox]) {
          c.addError(e);
        }
      }
    } finally {
      _running = false;
    }
  }

  /// [f], or null when the daemon refuses it as forbidden (relay devices).
  static Future<T?> _unlessForbidden<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on AgentdError catch (e) {
      if (e.isForbidden) return null;
      rethrow;
    }
  }

  void _emit(List<MailMessage>? mail, List<WorkQueue> queues) {
    if (mail != null && !_sameMail(_lastMail, mail)) {
      _lastMail = List.unmodifiable(mail);
      for (final c in [..._inbox]) {
        c.add(_lastMail!);
      }
    }
    if (!_sameQueues(_lastQueues, queues)) {
      _lastQueues = List.unmodifiable(queues);
      for (final c in [..._queues]) {
        c.add(_lastQueues!);
      }
    }
  }

  static bool _sameMail(List<MailMessage>? a, List<MailMessage> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].state != b[i].state || a[i].to != b[i].to) return false;
    }
    return true;
  }

  static bool _sameQueues(List<WorkQueue>? a, List<WorkQueue> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].name != b[i].name || a[i].unclaimed != b[i].unclaimed) return false;
    }
    return true;
  }
}
