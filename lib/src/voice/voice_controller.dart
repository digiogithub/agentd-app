// The hands-free voice mode: a conversation over Bluetooth headphones with
// the agents of the Panel, on top of [CarHub] (what is open, the actions)
// and a [VoicePort] (speech, recognition, sounds, headset buttons).
//
// States: off -> armed (waits for a button) -> listening -> acting ->
// speaking -> a short follow-up listen -> armed. Buttons, while armed:
// play/pause talks (or reads what was just announced), next repeats the
// last thing said (or reads the announced item, or the pending items),
// previous reads the pending items. Play/pause while speaking cuts the
// speech and listens (barge-in); next while speaking cuts it.
//
// Nothing reaches an agent without a spoken "sí": every answer and
// instruction is read back ("A api: «…». ¿Envío?"), launching and stopping
// ask "¿Seguro?", and silence cancels. Never log what is said or heard.

import 'dart:async';

import '../car/car_hub.dart';
import '../car/car_text.dart';
import '../core/contracts.dart';
import 'voice_grammar.dart';
import 'voice_port.dart';

enum VoiceState { off, armed, listening, acting, speaking }

/// Starts a timer (tests pass a fake one).
typedef VoiceTimerFactory = Timer Function(Duration duration, void Function() callback);

class VoiceController {
  VoiceController({
    required this.port,
    required this.hub,
    VoiceTimerFactory? timer,
    DateTime Function()? now,
    this.listenMax = const Duration(seconds: 8),
    this.followUpMax = const Duration(seconds: 6),
    this.confirmMax = const Duration(seconds: 10),
    this.idleTimeout = const Duration(minutes: 20),
    this.projectsTtl = const Duration(minutes: 5),
    this.projectsTimeout = const Duration(seconds: 3),
    this.noticeDelay = const Duration(milliseconds: 300),
  })  : _timer = timer ?? Timer.new,
        _now = now ?? DateTime.now;

  final VoicePort port;
  final CarHub hub;
  final VoiceTimerFactory _timer;
  final DateTime Function() _now;

  /// One listen for a command.
  final Duration listenMax;

  /// The listen right after an answer (no reprompt).
  final Duration followUpMax;

  /// The wait for "sí" / "no" of a confirmation; silence cancels.
  final Duration confirmMax;

  /// Armed this long without a button press: voice mode ends.
  final Duration idleTimeout;
  final Duration projectsTtl;
  final Duration projectsTimeout;

  /// Notices that arrive together are announced together.
  final Duration noticeDelay;

  final _states = StreamController<VoiceState>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];
  final _queued = <CarNotice>[];
  final _announced = <CarNotice>[];
  VoiceState _state = VoiceState.off;
  Future<void>? _running;
  Timer? _idle;
  Timer? _noticeTimer;
  String? _current;
  String? _last;
  bool _bargeIn = false;
  List<VoiceProject> _projects = const [];
  DateTime? _projectsAt;

  VoiceState get state => _state;
  Stream<VoiceState> get states => _states.stream;

  /// Key of the agent spoken to.
  String? get current => _current;

  bool get _busy => _running != null;

  void _set(VoiceState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// Turns voice mode on: armed, listening to the buttons and the notices.
  Future<void> start() async {
    if (_state != VoiceState.off) return;
    hub.start();
    _set(VoiceState.armed);
    _subs
      ..add(port.buttons.listen(_onButton))
      ..add(hub.notices.listen(_onNotice))
      ..add(hub.cancels.listen((tag) {
        _queued.removeWhere((n) => n.tag == tag);
        _announced.removeWhere((n) => n.tag == tag);
      }));
    _resetIdle();
    _job(() async {
      if (await _say('Modo voz. Pulsa para hablar.', remember: false)) await _converse();
    });
  }

  /// Completes when the controller has nothing in progress.
  Future<void> whenIdle() async {
    await Future<void>.delayed(Duration.zero);
    while (_running != null) {
      await _running;
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Turns voice mode off without speaking (the platform ended it).
  Future<void> dispose() async {
    _set(VoiceState.off);
    _idle?.cancel();
    _noticeTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _states.close();
  }

  // -------------------------------------------------------------------------
  // Events

  void _onButton(VoiceButton b) {
    if (_state == VoiceState.off) return;
    _resetIdle();
    if (_state == VoiceState.speaking) {
      if (b == VoiceButton.playPause) _bargeIn = true;
      unawaited(port.stopSpeaking().catchError((Object _) {}));
      return;
    }
    if (_state != VoiceState.armed || _busy) return;
    switch (b) {
      case VoiceButton.playPause:
        _job(() => _announced.isNotEmpty ? _readAnnounced() : _converse());
      case VoiceButton.next:
        _job(() async {
          if (_announced.isNotEmpty) return _readAnnounced();
          final text = _last ?? _pendingText();
          if (await _say(text)) await _converse();
        });
      case VoiceButton.previous:
        _job(() async {
          if (await _say(_pendingText())) await _converse();
        });
    }
  }

  /// Times each item was announced (by session and text): at most
  /// [maxAnnouncements], so an item that comes back never loops.
  final _announceCount = <String, int>{};
  static const maxAnnouncements = 2;

  void _onNotice(CarNotice n) {
    if (_state == VoiceState.off) return;
    if (_queued.any((q) => q.tag == n.tag) || _announced.any((q) => q.tag == n.tag)) return;
    final id = '${n.sessionKey}|${n.title}|${n.text}';
    final times = _announceCount[id] ?? 0;
    if (times >= maxAnnouncements) return;
    _announceCount[id] = times + 1;
    _queued.add(n);
    _noticeTimer ??= _timer(noticeDelay, () {
      _noticeTimer = null;
      _drain();
    });
  }

  /// Announces the queued notices when armed: "api pregunta. Pulsa para oír."
  void _drain() {
    if (_queued.isEmpty || _busy || _noticeTimer != null || _state != VoiceState.armed) return;
    final fresh = [..._queued];
    _queued.clear();
    _announced.addAll(fresh);
    final names = {for (final n in fresh) _spoken(n.session)}.toList();
    final text = fresh.length == 1
        ? '${names.single} ${fresh.single.tag.startsWith('q/') ? 'pregunta' : 'espera tu decisión'}. Pulsa para oír.'
        : '${names.length == 1 ? names.single : '${names.sublist(0, names.length - 1).join(', ')} y ${names.last}'} esperan. Pulsa para oír.';
    _job(() async {
      if (await _say(text, remember: false)) await _readAnnounced();
    });
  }

  void _resetIdle() {
    _idle?.cancel();
    _idle = _timer(idleTimeout, _onIdle);
  }

  void _onIdle() {
    if (_state == VoiceState.off) return;
    if (_busy) return _resetIdle();
    _job(_exit);
  }

  /// Runs [body] as the one thing in progress; back to armed afterwards.
  void _job(Future<void> Function() body) {
    if (_busy || _state == VoiceState.off) return;
    late final Future<void> f;
    f = () async {
      try {
        await body();
      } catch (_) {
        // A failing port must not leave voice mode stuck.
      } finally {
        if (identical(_running, f)) _running = null;
        if (_state != VoiceState.off) {
          _set(VoiceState.armed);
          _resetIdle();
          _drain();
        }
      }
    }();
    _running = f;
  }

  // -------------------------------------------------------------------------
  // Speech

  /// Says [text]; true when play/pause cut it (the user wants to talk).
  Future<bool> _say(String text, {bool remember = true}) async {
    final t = speakable(text);
    if (t.isEmpty || _state == VoiceState.off) return false;
    if (remember) _last = t;
    _bargeIn = false;
    _set(VoiceState.speaking);
    try {
      await port.say(t);
    } catch (_) {}
    if (_state != VoiceState.off) _set(VoiceState.acting);
    final b = _bargeIn;
    _bargeIn = false;
    return b;
  }

  Future<VoiceHeard> _listen(Duration max) async {
    if (_state == VoiceState.off) return const VoiceHeard.error('other');
    _set(VoiceState.listening);
    VoiceHeard h;
    try {
      unawaited(port.earcon(Earcon.listenStart).catchError((Object _) {}));
      h = await port.listen(max: max);
    } catch (_) {
      h = const VoiceHeard.error('other');
    }
    unawaited(port.earcon(Earcon.listenEnd).catchError((Object _) {}));
    if (_state != VoiceState.off) _set(VoiceState.acting);
    return h;
  }

  void _earcon(Earcon e) => unawaited(port.earcon(e).catchError((Object _) {}));

  static String _heardError(String? code) => switch (code) {
        'audio' => 'No te oigo: el micrófono no responde.',
        'network' => 'No hay red para reconocer la voz.',
        'busy' => 'El reconocimiento de voz está ocupado.',
        _ => 'No se pudo escuchar.',
      };

  /// Listen, act, answer, listen again shortly; back to armed on silence.
  Future<void> _converse({bool followUp = false}) async {
    var follow = followUp;
    var reprompted = false;
    while (_state != VoiceState.off) {
      final heard = await _listen(follow ? followUpMax : listenMax);
      if (heard.error == 'permission') {
        await _exit(text: 'Necesito permiso de micrófono.');
        return;
      }
      if (heard.isEmpty) {
        if (follow) return;
        if (heard.isSilence && !reprompted) {
          reprompted = true;
          await _say('¿Sí?', remember: false);
          continue;
        }
        if (!heard.isSilence) await _say(_heardError(heard.error), remember: false);
        return;
      }
      final out = await _act(parse(heard.alts, await _context()));
      if (out == null || _state == VoiceState.off) return;
      final barged = await _say(out);
      follow = !barged;
      reprompted = !barged;
    }
  }

  Future<void> _readAnnounced() async {
    final n = _announced.removeAt(0);
    _current = n.sessionKey;
    final barged = await _say('${_spoken(n.title)}. ${n.text}');
    await _converse(followUp: !barged);
  }

  Future<void> _exit({String text = 'Salgo del modo voz.'}) async {
    await _say(text, remember: false);
    _set(VoiceState.off);
    _idle?.cancel();
    _noticeTimer?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    try {
      await port.exit();
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // What the controller knows

  List<_Agent> _agents() => [
        for (final a in (hub.snapshot['agents'] as List? ?? const []).whereType<Map<Object?, Object?>>()) _Agent(a),
      ];

  List<Map<Object?, Object?>> _hostEntries() => (hub.snapshot['hostEntries'] as List? ?? const []).whereType<Map<Object?, Object?>>().toList();

  Future<VoiceContext> _context() async {
    final agents = _agents();
    final cur = agents.where((a) => a.key == _current).firstOrNull;
    return VoiceContext(
      agents: [for (final a in agents) VoiceAgent(key: a.key, name: a.name, host: a.host, hostId: a.hostId)],
      current: cur?.key,
      options: cur?.options ?? const [],
      projects: await _loadProjects(),
    );
  }

  Future<List<VoiceProject>> _loadProjects() async {
    final at = _projectsAt;
    if (at != null && _now().difference(at) < projectsTtl) return _projects;
    final out = <VoiceProject>[];
    for (final h in _hostEntries()) {
      if (h['online'] != true || h['canAdmin'] != true) continue;
      final id = h['id']! as String;
      try {
        for (final p in await hub.projects(id).timeout(projectsTimeout)) {
          out.add(VoiceProject(name: p, hostId: id, host: h['name'] as String? ?? id));
        }
      } catch (_) {
        // A host that does not answer offers no projects this time.
      }
    }
    _projects = out;
    _projectsAt = _now();
    return out;
  }

  static String _spoken(String name) => name.replaceAll('@', ' de ');

  String _pendingText() {
    final items = <String>[];
    for (final a in _agents()) {
      for (final q in a.questions) {
        items.add('${_spoken(a.name)} pregunta: ${truncateWords(q, 160)}');
      }
      if (a.menuQuestion != null) items.add('${_spoken(a.name)} ${a.menuVerb}: ${truncateWords(a.menuQuestion!, 160)}');
      for (final t in a.blocked) {
        items.add('${_spoken(a.name)} bloqueado: ${truncateWords(t, 120)}');
      }
    }
    return items.isEmpty ? 'Nada pendiente.' : '${items.join('.\n')}.';
  }

  /// The agent a command is about: the one named, the current one, the only
  /// one waiting, or the only one there is.
  _Agent _target(String? named) {
    final agents = _agents();
    final key = named ?? _current;
    if (key != null) {
      final a = agents.where((a) => a.key == key).firstOrNull;
      if (a == null) throw const CarActionException('Ese agente ya no está');
      return _pick(a);
    }
    final waiting = agents.where((a) => a.waits).toList();
    if (waiting.length == 1) return _pick(waiting.single);
    if (agents.length == 1) return _pick(agents.single);
    if (agents.isEmpty) throw const CarActionException('No hay agentes conectados');
    throw const CarActionException('¿Qué agente? Di su número o su nombre.');
  }

  _Agent _pick(_Agent a) {
    _current = a.key;
    return a;
  }

  void _checkOperate(_Agent a) {
    if (!a.canOperate) throw const CarActionException('Este dispositivo solo puede mirar en ese host');
  }

  // -------------------------------------------------------------------------
  // Commands

  /// Runs [c]; the text to say, or null when nothing more is said.
  Future<String?> _act(VoiceCommand c) async {
    try {
      return await _do(c);
    } on CarActionException catch (e) {
      _earcon(Earcon.error);
      return e.message;
    } catch (_) {
      _earcon(Earcon.error);
      return 'No se pudo.';
    }
  }

  Future<String?> _do(VoiceCommand c) async {
    switch (c) {
      case ListAgentsCommand():
        final agents = _agents();
        if (agents.isEmpty) return 'No hay agentes conectados.';
        final manyHosts = agents.map((a) => a.hostId).toSet().length > 1;
        final n = agents.length == 1 ? 'Un agente' : '${agents.length} agentes';
        return '$n.\n${[for (final (i, a) in agents.indexed) '${i + 1}, ${_spoken(a.name)}${manyHosts ? ' en ${a.host}' : ''}, ${a.statusText}.'].join('\n')}';
      case PendingCommand():
        final waiting = _agents().where((a) => a.waits || a.blocked.isNotEmpty).toList();
        if (waiting.length == 1) _current = waiting.single.key;
        return _pendingText();
      case PickAgentCommand(:final key):
        return _describe(_target(key));
      case AmbiguousAgentCommand(:final keys):
        final agents = _agents();
        final names = [
          for (final (i, a) in agents.indexed)
            if (keys.contains(a.key)) '${i + 1}, ${_spoken(a.name)} en ${a.host}',
        ];
        return '¿Cuál? ${names.join(', o ')}.';
      case ConclusionCommand(:final agent):
        return hub.conclusion(_target(agent).key);
      case LastLinesCommand(:final agent):
        final a = _target(agent);
        final lines = await hub.lastLines(a.key, 5);
        return lines.isEmpty ? '${_spoken(a.name)} no tiene nada todavía.' : lines.join('\n');
      case ReadQuestionCommand(:final agent):
        final a = _target(agent);
        if (a.questionBodies.isNotEmpty) {
          final opts = a.questionOptions.isEmpty ? '' : '\nOpciones: ${spokenOptions(a.questionOptions)}';
          return '${truncateWords(a.questionBodies.first.trim(), 600)}$opts';
        }
        if (a.menuQuestion != null) {
          final detail = (a.menuDetail ?? '').trim().isEmpty ? '' : '\n${a.menuDetail!.trim()}';
          final opts = a.menuOptions.isEmpty ? '' : '\nOpciones: ${spokenOptions(a.menuOptions)}';
          return '${truncateWords(a.menuQuestion!.trim(), 400)}$detail$opts';
        }
        return '${_spoken(a.name)} no pregunta nada.';
      case AnswerCommand(:final text):
        final a = _target(null);
        _checkOperate(a);
        return _send(a, text);
      case DictateCommand(:final text):
        final a = _target(null);
        _checkOperate(a);
        var t = text;
        if (t == null) {
          await _say('Dicta.', remember: false);
          final h = await _listen(listenMax);
          if (h.isEmpty) return 'Cancelado.';
          t = h.alts.firstWhere((x) => x.trim().isNotEmpty).trim();
        }
        return _send(a, t);
      case LaunchCommand(:final project, :final harness):
        if (project == null) {
          final names = {for (final p in _projects) p.name}.toList();
          if (names.isEmpty) {
            final admin = _hostEntries().any((h) => h['online'] == true && h['canAdmin'] == true);
            return admin ? 'No hay proyectos para lanzar.' : 'Este dispositivo no puede lanzar agentes.';
          }
          return 'No conozco ese proyecto. Proyectos: ${names.take(8).join(', ')}.';
        }
        if (!await _confirm('¿Seguro? Nuevo $harness en ${project.name} de ${project.host}.')) return 'Cancelado.';
        final s = await hub.launch(project.hostId, project.name, harness: harness);
        _current = s.key;
        _earcon(Earcon.ok);
        return 'Lanzado $harness en ${project.name}.';
      case StopCommand(:final agent):
        final a = _target(agent);
        _checkOperate(a);
        if (!await _confirm('¿Seguro? Paro a ${_spoken(a.name)}.')) return 'Cancelado.';
        await hub.interrupt(a.key);
        _earcon(Earcon.ok);
        return 'Parado ${_spoken(a.name)}.';
      case RepeatCommand():
        return _last ?? 'Nada que repetir.';
      case HelpCommand():
        return 'Puedes decir: agentes, pendientes, el número o el nombre de un agente, conclusión, últimas líneas, pregunta, '
            'opción dos, responde y tu respuesta, dicta, para, nuevo agente en un proyecto, repite y salir.';
      case ExitCommand():
        await _exit();
        return null;
      case UnknownCommand():
        return 'No te he entendido. Di ayuda para oír las órdenes.';
    }
  }

  String _describe(_Agent a) {
    final head = '${_spoken(a.name)} en ${a.host}.';
    if (a.questionBodies.isNotEmpty) {
      final opts = a.questionOptions.isEmpty ? '' : ' Opciones: ${spokenOptions(a.questionOptions)}';
      return '$head Pregunta: ${truncateWords(a.questions.first, 200)}.$opts';
    }
    if (a.menuQuestion != null) {
      final opts = a.menuOptions.isEmpty ? '' : ' Opciones: ${spokenOptions(a.menuOptions)}';
      return '$head ${a.menuVerb[0].toUpperCase()}${a.menuVerb.substring(1)}: ${truncateWords(a.menuQuestion!, 200)}.$opts';
    }
    final doing = a.preview == null || a.preview!.trim().isEmpty ? '' : ' ${truncateWords(a.preview!.trim(), 120)}';
    return '$head ${a.statusText[0].toUpperCase()}${a.statusText.substring(1)}.$doing';
  }

  /// Reads [text] back to [a] and sends it only on a spoken yes.
  Future<String> _send(_Agent a, String text) async {
    var t = text.trim();
    var doubted = false;
    while (_state != VoiceState.off) {
      await _say('A ${_spoken(a.name)}: «$t». ¿Envío?', remember: false);
      final h = await _listen(confirmMax);
      if (h.isEmpty) return 'Cancelado.';
      switch (parseConfirm(h.alts)) {
        case VoiceConfirm.yes:
          final r = await hub.reply(a.key, t);
          _earcon(Earcon.ok);
          return r;
        case VoiceConfirm.no:
          return 'Cancelado.';
        case VoiceConfirm.redo:
          await _say('Dicta de nuevo.', remember: false);
          final d = await _listen(listenMax);
          if (d.isEmpty) return 'Cancelado.';
          t = d.alts.firstWhere((x) => x.trim().isNotEmpty).trim();
          doubted = false;
        case VoiceConfirm.unknown:
          if (doubted) return 'Cancelado.';
          doubted = true;
      }
    }
    return 'Cancelado.';
  }

  /// [question], then true only on a spoken yes (one retry on a doubt).
  Future<bool> _confirm(String question) async {
    for (var i = 0; i < 2 && _state != VoiceState.off; i++) {
      await _say(question, remember: false);
      final h = await _listen(confirmMax);
      if (h.isEmpty) return false;
      switch (parseConfirm(h.alts)) {
        case VoiceConfirm.yes:
          return true;
        case VoiceConfirm.no:
          return false;
        case VoiceConfirm.redo || VoiceConfirm.unknown:
          continue;
      }
    }
    return false;
  }
}

/// An agent entry of the [CarHub] snapshot.
class _Agent {
  _Agent(this._m);
  final Map<Object?, Object?> _m;

  String get key => _m['key'] as String? ?? '';
  String get name => _m['name'] as String? ?? '';
  String get host => _m['host'] as String? ?? '';
  String get hostId => _m['hostId'] as String? ?? '';
  String? get preview => _m['preview'] as String?;
  bool get canOperate => _m['canOperate'] == true;

  List<Map<Object?, Object?>> get _questions => (_m['questions'] as List? ?? const []).whereType<Map<Object?, Object?>>().toList();
  List<String> get questions => [for (final q in _questions) (q['headline'] as String?) ?? (q['body'] as String? ?? '')];
  List<String> get questionBodies => [for (final q in _questions) q['body'] as String? ?? ''];
  List<String> get questionOptions => _questions.isEmpty ? const [] : (_questions.first['options'] as List? ?? const []).whereType<String>().toList();

  Map<Object?, Object?>? get _menu => _m['menu'] as Map<Object?, Object?>?;
  String? get menuQuestion => _menu?['question'] as String?;
  String? get menuDetail => _menu?['detail'] as String?;
  String get menuVerb => _menu?['kind'] == PendingKind.permission.name ? 'pide permiso' : 'espera tu decisión';
  List<String> get menuOptions => [
        for (final o in (_menu?['options'] as List? ?? const []).whereType<Map<Object?, Object?>>()) o['label'] as String? ?? '',
      ];

  List<String> get blocked => [for (final t in (_m['blocked'] as List? ?? const []).whereType<Map<Object?, Object?>>()) t['title'] as String? ?? ''];

  /// A question or a menu is open.
  bool get waits => _questions.isNotEmpty || _menu != null;

  /// Options an answer can name: the oldest question's, else the menu's.
  List<String> get options => questionOptions.isNotEmpty || _questions.isNotEmpty ? questionOptions : menuOptions;

  String get statusText {
    if (_questions.isNotEmpty) return 'pregunta';
    if (_menu != null) return menuVerb;
    if (blocked.isNotEmpty) return 'bloqueado';
    return switch (_m['status']) {
      'working' => 'trabajando',
      'waiting' => 'esperando',
      'idle' => 'libre',
      'starting' => 'arrancando',
      'exited' => 'terminado',
      _ => 'sin estado',
    };
  }
}
