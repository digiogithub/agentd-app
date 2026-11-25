// What the Android Auto client sees and does, on top of the repositories:
// a snapshot of the Panel (questions, terminal menus, blocked tasks, agents)
// pushed on every change, the messages to notify (new questions and menus),
// and the actions a driver takes by voice or touch (answer, choose, prompt,
// hear the conclusion or the last lines).
//
// Pure Dart: the platform side (`car_bridge.dart`) only moves maps over a
// MethodChannel. Never log the texts: they are agent or user writing.

import 'dart:async';

import '../core/contracts.dart';
import '../ui/panel_model.dart';
import 'car_text.dart';

/// A notification the car shows (and Google Assistant reads) for something
/// that waits for the driver. [tag] is stable while the item is open.
class CarNotice {
  const CarNotice({required this.tag, required this.sessionKey, required this.session, required this.host, required this.title, required this.text});
  final String tag;
  final String sessionKey;
  final String session;
  final String host;
  final String title;
  final String text;

  Map<String, Object?> toMap() => {'tag': tag, 'sessionKey': sessionKey, 'session': session, 'host': host, 'title': title, 'text': text};
}

/// Why a car action was refused, in words for the driver (Spanish).
class CarActionException implements Exception {
  const CarActionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CarHub {
  CarHub({required this.hosts, required this.sessions, required this.board, this.debounce = const Duration(milliseconds: 300), this.viewTimeout = const Duration(seconds: 10), this.settleTimeout = const Duration(seconds: 20)});

  final HostsRepository hosts;
  final SessionsRepository sessions;
  final BoardRepository board;
  final Duration debounce;
  final Duration viewTimeout;

  /// How long an action waits for the host's board and sessions after a
  /// cold start (a reply from a notification starts the engine).
  final Duration settleTimeout;

  final _snapshots = StreamController<Map<String, Object?>>.broadcast();
  final _notices = StreamController<CarNotice>.broadcast();
  final _cancels = StreamController<String>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];
  final _boardSubs = <String, StreamSubscription<HostBoard>>{};
  final _boards = <String, HostBoard>{};
  final _noticed = <String>{};
  List<HostStatus> _hosts = const [];
  List<AgentSession> _sessions = const [];
  Map<String, Object?> _snapshot = const {'hosts': 0, 'online': 0, 'agents': <Object?>[]};
  Timer? _timer;
  bool _started = false;

  /// The Panel, again on every change (debounced).
  Stream<Map<String, Object?>> get snapshots => _snapshots.stream;

  /// A new question or terminal menu.
  Stream<CarNotice> get notices => _notices.stream;

  /// The tag of a notice whose item is no longer open.
  Stream<String> get cancels => _cancels.stream;

  Map<String, Object?> get snapshot => _snapshot;

  void start() {
    if (_started) return;
    _started = true;
    _subs
      ..add(hosts.watch().listen((h) {
        _hosts = h;
        _syncBoards();
        _schedule();
      }))
      ..add(sessions.watch().listen((s) {
        _sessions = s;
        _schedule();
      }));
  }

  void _syncBoards() {
    final online = {for (final h in _hosts) if (h.state == HostState.online) h.config.id};
    for (final id in _boardSubs.keys.toList()) {
      if (!online.contains(id)) {
        unawaited(_boardSubs.remove(id)!.cancel());
        _boards.remove(id);
      }
    }
    for (final id in online) {
      _boardSubs[id] ??= board.watch(id).listen((b) {
        _boards[id] = b;
        _schedule();
      }, onError: (Object _) {});
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, rebuild);
  }

  HostConfig? _config(String hostId) => _hosts.where((h) => h.config.id == hostId).firstOrNull?.config;

  AgentSession? _session(String key) => _sessions.where((s) => s.key == key).firstOrNull;

  /// Recomputes the snapshot and the notices now.
  void rebuild() {
    _timer?.cancel();
    final online = [for (final h in _hosts) if (h.state == HostState.online) h.config.id];
    final panel = buildPanel(boards: [for (final id in online) ?_boards[id]], sessions: [for (final s in _sessions) if (online.contains(s.hostId)) s]);
    final agents = <Map<String, Object?>>[];
    final open = <String, CarNotice>{};
    for (final a in panel.agents) {
      final cfg = _config(a.hostId);
      final host = cfg?.name ?? a.hostId;
      final canOperate = cfg?.canOperate ?? false;
      final live = _session(a.key);
      final menu = live?.pending;
      final blocked = [for (final t in a.tasks) if (t.status == TaskStatus.blocked) t];
      agents.add({
        'key': a.key,
        'hostId': a.hostId,
        'host': host,
        'name': a.name,
        'status': a.status.name,
        'preview': a.preview,
        'current': a.current?.title,
        'done': a.done,
        'total': a.total,
        'canOperate': canOperate,
        'blocked': [for (final t in blocked) {'title': t.title, 'note': t.note}],
        'questions': [
          for (final q in a.questions) {'id': q.id, 'body': q.body, 'headline': splitQuestion(q.body).$1, 'options': q.options},
        ],
        'menu': menu == null
            ? null
            : {
                'kind': menu.kind.name,
                'question': menu.question,
                'detail': menu.detail,
                'options': [for (final o in menu.options) {'id': o.id, 'label': o.label}],
              },
      });
      if (!canOperate) continue;
      for (final q in a.questions) {
        final tag = 'q/${a.hostId}/${q.id}';
        final opts = q.options.isEmpty ? '' : '\nOpciones: ${spokenOptions(q.options)}';
        open[tag] = CarNotice(tag: tag, sessionKey: a.key, session: a.name, host: host, title: '${a.name} te pregunta', text: '${truncateWords(q.body.trim(), 600)}$opts');
      }
      if (menu != null) {
        final tag = 'm/${a.key}/${menu.revision ?? menu.question.hashCode}';
        final what = menu.kind == PendingKind.permission ? 'pide permiso' : 'espera tu decisión';
        final detail = (menu.detail ?? '').trim().isEmpty ? '' : '\n${menu.detail!.trim()}';
        final opts = menu.options.isEmpty ? '' : '\nOpciones: ${spokenOptions([for (final o in menu.options) o.label])}';
        open[tag] = CarNotice(tag: tag, sessionKey: a.key, session: a.name, host: host, title: '${a.name} $what', text: '${truncateWords(menu.question.trim(), 400)}$detail$opts');
      }
    }
    _snapshot = {'hosts': _hosts.length, 'online': online.length, 'agents': agents};
    if (!_snapshots.isClosed) _snapshots.add(_snapshot);
    for (final tag in _noticed.difference(open.keys.toSet()).toList()) {
      _noticed.remove(tag);
      if (!_cancels.isClosed) _cancels.add(tag);
    }
    for (final n in open.values) {
      if (_noticed.add(n.tag) && !_notices.isClosed) _notices.add(n);
    }
  }

  BoardSession? _boardSession(String key) {
    for (final b in _boards.values) {
      for (final s in b.sessions) {
        if (s.key == key) return s;
      }
    }
    return null;
  }

  /// Waits (up to [settleTimeout]) until the host of [key] has its board and
  /// knows the session: a voice reply must not take an open question for a
  /// free instruction only because the board is still loading.
  Future<void> _settle(String key) async {
    final i = key.indexOf('/${SessionSource.agentd.name}/');
    final hostId = i < 0 ? key : key.substring(0, i);
    final deadline = DateTime.now().add(settleTimeout);
    while (!(_boards.containsKey(hostId) && (_session(key) != null || _boardSession(key) != null))) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero || _snapshots.isClosed) return;
      try {
        await _snapshots.stream.first.timeout(left);
      } on TimeoutException {
        return;
      }
    }
  }

  /// The live session of [key], or a bare agentd one when only the board
  /// knows it.
  AgentSession _target(String key) {
    final s = _session(key);
    if (s != null) return s;
    final b = _boardSession(key);
    if (b != null) return AgentSession(hostId: b.hostId, source: SessionSource.agentd, name: b.name, status: b.status);
    throw const CarActionException('Ese agente ya no está');
  }

  void _checkOperate(String hostId) {
    if (!(_config(hostId)?.canOperate ?? false)) throw const CarActionException('Este dispositivo solo puede mirar en ese host');
  }

  /// Answers question [questionId] of [hostId] with [text].
  Future<void> answer(String hostId, int questionId, String text) async {
    if (_config(hostId) == null) await hosts.watch().firstWhere((h) => h.any((x) => x.config.id == hostId)).timeout(settleTimeout, onTimeout: () => const []);
    _checkOperate(hostId);
    await board.answer(hostId, questionId, text);
  }

  /// Chooses option [optionId] of the menu [key] waits on.
  Future<void> choose(String key, String optionId) async {
    await _settle(key);
    final s = _target(key);
    _checkOperate(s.hostId);
    final p = s.pending;
    if (p == null) throw const CarActionException('Ese menú ya no está abierto');
    final o = p.options.where((o) => o.id == optionId).firstOrNull;
    if (o == null || p.revision == null || p.epoch == null) throw const CarActionException('Esa opción ya no está');
    await sessions.choose(s, o, revision: p.revision!, epoch: p.epoch!);
  }

  /// Types [text] in the agent's prompt.
  Future<void> prompt(String key, String text) async {
    await _settle(key);
    final s = _target(key);
    _checkOperate(s.hostId);
    if (s.status == AgentStatus.exited) throw const CarActionException('Esa sesión ha terminado');
    await sessions.prompt(s, text);
  }

  /// A dictated reply to agent [key]: it answers the oldest open question
  /// (the option it names, or the words as said), else picks the terminal
  /// menu option it names, else goes to the prompt as an instruction.
  /// Returns what happened, to be read to the driver.
  Future<String> reply(String key, String text) async {
    final t = text.trim();
    if (t.isEmpty) throw const CarActionException('No he oído nada');
    await _settle(key);
    final s = _target(key);
    _checkOperate(s.hostId);
    final q = _boardSession(key)?.questions.firstOrNull;
    if (q != null) {
      final i = matchSpokenOption(t, q.options);
      final body = i == null ? t : q.options[i];
      await board.answer(s.hostId, q.id, body);
      return i == null ? 'Respuesta enviada a ${s.name}' : 'Respondido a ${s.name}: $body';
    }
    final p = s.pending;
    if (p != null && p.options.isNotEmpty) {
      final i = matchSpokenOption(t, [for (final o in p.options) o.label]);
      if (i == null) throw CarActionException('No sé qué opción es. ${spokenOptions([for (final o in p.options) o.label])}');
      await choose(key, p.options[i].id);
      return 'Elegido en ${s.name}: ${p.options[i].label}';
    }
    await prompt(key, t);
    return 'Instrucción enviada a ${s.name}';
  }

  Future<List<ChatItem>> _items(String key) async {
    await _settle(key);
    final s = _target(key);
    try {
      final v = await sessions.view(s).firstWhere((v) => v.items.isNotEmpty).timeout(viewTimeout);
      return v.items;
    } on TimeoutException {
      return const [];
    } on StateError {
      return const [];
    }
  }

  /// The agent's last message, ready to be read aloud.
  Future<String> conclusion(String key) async {
    final c = conclusionOf(await _items(key));
    if (c == null) return '${_target(key).name} no ha dicho nada todavía';
    return speakable(c);
  }

  /// The last [n] lines of the session.
  Future<List<String>> lastLines(String key, int n) async => lastLinesOf(await _items(key), n);

  /// Asks every host for a fresh connection (the car came back online).
  Future<void> refresh() => hosts.reconnectAll();

  Future<void> dispose() async {
    _timer?.cancel();
    for (final s in [..._subs, ..._boardSubs.values]) {
      await s.cancel();
    }
    await _snapshots.close();
    await _notices.close();
    await _cancels.close();
  }
}
