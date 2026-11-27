// The spoken commands of the hands-free voice mode (Spanish), parsed from the
// recognizer's alternatives. Pure: what the controller knows (agents, the
// current one, its open options, the projects it can launch in) comes in a
// [VoiceContext]. Matching ignores case, accents and punctuation
// (`normalizeSpoken`) and tolerates fillers ("el", "de", "agente").
//
// Numbers: "agente dos" and "el dos" pick agent 2; "opción dos" and "la
// segunda" answer option 2; a bare "dos" answers an option when the current
// agent has options open, else picks agent 2.

import '../car/car_text.dart';

/// An agent as the voice mode lists it; its number is its index + 1.
class VoiceAgent {
  const VoiceAgent({required this.key, required this.name, required this.host, this.hostId = ''});
  final String key;
  final String name; // codex@api
  final String host; // host display name
  final String hostId;
}

/// A project a new agent can be launched in.
class VoiceProject {
  const VoiceProject({required this.name, required this.hostId, required this.host});
  final String name;
  final String hostId;
  final String host;
}

class VoiceContext {
  const VoiceContext({this.agents = const [], this.current, this.options = const [], this.projects = const []});
  final List<VoiceAgent> agents;

  /// Key of the agent spoken to, if any.
  final String? current;

  /// Options of the current agent's open question or menu.
  final List<String> options;
  final List<VoiceProject> projects;

  VoiceAgent? get currentAgent => agents.where((a) => a.key == current).firstOrNull;
}

sealed class VoiceCommand {
  const VoiceCommand();
}

class ListAgentsCommand extends VoiceCommand {
  const ListAgentsCommand();
}

class PendingCommand extends VoiceCommand {
  const PendingCommand();
}

/// Talk to agent [key] from now on.
class PickAgentCommand extends VoiceCommand {
  const PickAgentCommand(this.key);
  final String key;
}

/// The name said fits several agents.
class AmbiguousAgentCommand extends VoiceCommand {
  const AmbiguousAgentCommand(this.keys);
  final List<String> keys;
}

/// A command about one agent: [agent] when the phrase names one, else the
/// current agent.
sealed class AgentCommand extends VoiceCommand {
  const AgentCommand({this.agent});
  final String? agent;
}

class ConclusionCommand extends AgentCommand {
  const ConclusionCommand({super.agent});
}

class LastLinesCommand extends AgentCommand {
  const LastLinesCommand({super.agent});
}

class ReadQuestionCommand extends AgentCommand {
  const ReadQuestionCommand({super.agent});
}

/// Esc to the agent (asks for confirmation).
class StopCommand extends AgentCommand {
  const StopCommand({super.agent});
}

/// An answer to the current agent: [text] is the option label when
/// [option] (0-based) is set, else the words as said.
class AnswerCommand extends VoiceCommand {
  const AnswerCommand(this.text, {this.option});
  final String text;
  final int? option;
}

/// A free instruction; [text] null = the next recognition is the text.
class DictateCommand extends VoiceCommand {
  const DictateCommand([this.text]);
  final String? text;
}

/// A new agent: [project] null when the name said matches none ([heard]).
class LaunchCommand extends VoiceCommand {
  const LaunchCommand({this.project, this.harness = 'claude', this.heard = ''});
  final VoiceProject? project;
  final String harness;
  final String heard;
}

class RepeatCommand extends VoiceCommand {
  const RepeatCommand();
}

class HelpCommand extends VoiceCommand {
  const HelpCommand();
}

class ExitCommand extends VoiceCommand {
  const ExitCommand();
}

class UnknownCommand extends VoiceCommand {
  const UnknownCommand();
}

/// Harnesses a new agent can run, the default first.
const kVoiceHarnesses = ['claude', 'codex', 'pando', 'opencode', 'gemini', 'grok'];

/// How recognizers write the harness names.
const _harnessAliases = <String, String>{
  'claude': 'claude', 'claude code': 'claude', 'cloud': 'claude', 'cloud code': 'claude', 'clod': 'claude', 'claud': 'claude', 'clau': 'claude',
  'codex': 'codex', 'codecs': 'codex', 'codes': 'codex', 'kodex': 'codex', 'codec': 'codex',
  'pando': 'pando', 'panda': 'pando',
  'opencode': 'opencode', 'open code': 'opencode', 'open cod': 'opencode',
  'gemini': 'gemini', 'geminis': 'gemini', 'yemini': 'gemini', 'jemini': 'gemini', 'gemini cli': 'gemini',
  'grok': 'grok', 'grock': 'grok', 'groc': 'grok',
};

/// The best command among the recognizer's alternatives (best first): the
/// highest score wins, the earlier alternative on a tie.
VoiceCommand parse(List<String> alts, VoiceContext ctx) {
  VoiceCommand best = const UnknownCommand();
  var score = 0.0;
  for (final a in alts) {
    final (c, s) = _parseOne(a, ctx);
    if (s > score) {
      best = c;
      score = s;
    }
  }
  return best;
}

enum VoiceConfirm { yes, no, redo, unknown }

const _confirmYes = {'si', 'vale', 'envia', 'enviar', 'envialo', 'enviado', 'adelante', 'ok', 'okay', 'confirma', 'confirmo', 'confirmar', 'claro', 'de acuerdo', 'hazlo', 'seguro', 'si seguro', 'si envia', 'si envialo', 'si vale', 'si claro', 'venga', 'yes', 'manda', 'mandalo', 'dale', 'correcto'};
const _confirmNo = {'no', 'cancela', 'cancelar', 'cancelalo', 'nada', 'olvidalo', 'dejalo', 'deja', 'para', 'no envies', 'no lo envies', 'no gracias', 'mejor no', 'no cancela', 'tampoco', 'nunca'};
const _confirmRedo = {'repite', 'repitelo', 'otra vez', 'de nuevo', 'cambia', 'cambialo', 'corrige', 'corregir', 'no repite', 'vuelve a dictar', 'dicta otra vez', 'otra'};

/// A yes / no / dictate-again answer to a confirmation. Alternatives that
/// say yes and no at once are [VoiceConfirm.unknown]: nothing is sent on a
/// doubt.
VoiceConfirm parseConfirm(List<String> alts) {
  final said = [for (final a in alts) ?_confirmOf(normalizeSpoken(a))];
  if (said.contains(VoiceConfirm.yes) && said.contains(VoiceConfirm.no)) return VoiceConfirm.unknown;
  return said.firstOrNull ?? VoiceConfirm.unknown;
}

VoiceConfirm? _confirmOf(String s) {
  if (s.isEmpty) return null;
  if (_confirmRedo.contains(s)) return VoiceConfirm.redo;
  if (_confirmNo.contains(s) || s.startsWith('no ')) return VoiceConfirm.no;
  if (_confirmYes.contains(s)) return VoiceConfirm.yes;
  final w = s.split(' ');
  if (w.first == 'si' && w.skip(1).every(_confirmYes.contains)) return VoiceConfirm.yes;
  return null;
}

// ---------------------------------------------------------------------------

const _exit = ['salir del modo voz', 'sal del modo voz', 'cierra el modo voz', 'termina el modo voz', 'salir', 'sal', 'salte', 'termina', 'terminar', 'adios', 'hasta luego', 'fin'];
const _help = ['que puedo decir', 'que puedo hacer', 'que digo', 'ayuda', 'ayudame', 'comandos', 'ordenes'];
const _repeat = ['repitelo', 'repite', 'repetir', 'otra vez', 'como', 'que', 'perdona', 'no te he oido', 'no te oido'];
const _stopExact = ['paralo', 'para', 'parar', 'para el agente', 'detente', 'deten', 'detenlo', 'escape', 'esc', 'stop', 'interrumpe', 'interrumpelo', 'interrumpir', 'frena'];
const _stopPrefix = ['para', 'deten', 'detener', 'interrumpe', 'escape', 'stop', 'frena'];
const _list = ['que agentes hay', 'cuantos agentes hay', 'lista de agentes', 'lista los agentes', 'dime los agentes', 'agentes', 'lista', 'listado', 'quien hay', 'estado', 'que hay', 'sesiones'];
const _pending = ['que hay pendiente', 'que esta pendiente', 'que espera', 'que esperan', 'quien espera', 'pendientes', 'pendiente', 'preguntas', 'novedades', 'que falta', 'bloqueados', 'avisos'];
const _conclusion = ['que ha dicho', 'que ha respondido', 'que dice', 'lee la conclusion', 'conclusion', 'resumen', 'el final', 'final'];
const _lastLines = ['ultimas lineas', 'que esta haciendo', 'en que esta', 'que hace', 'lineas', 'ultimas'];
const _question = ['cual es la pregunta', 'lee la pregunta', 'lee las opciones', 'que opciones hay', 'que pregunta', 'la pregunta', 'las opciones', 'pregunta', 'opciones'];
const _dictate = ['nueva instruccion', 'dicta', 'dictar', 'dictado', 'instruccion', 'escribe', 'escribele', 'dile', 'manda', 'mandale'];
const _answer = ['responde', 'responder', 'respondele', 'contesta', 'contestale', 'respuesta'];
const _launch = ['nuevo agente', 'nueva sesion', 'abre un agente', 'abre agente', 'crea un agente', 'lanza un agente', 'arranca un agente', 'lanza', 'lanzar', 'arranca', 'nuevo', 'nueva'];
const _fillers = {'el', 'la', 'los', 'las', 'de', 'del', 'a', 'al', 'en', 'con', 'agente', 'sesion', 'que', 'por', 'favor', 'y', 'numero', 'pon', 'ponme', 'habla', 'hablar', 'elige', 'cambia', 've', 'vamos'};
const _yesNo = {'si', 'no', 'vale', 'si vale', 'no gracias', 'adelante'};

/// [phrase] at the start of [s] as whole words: the rest, or null.
String? _after(String s, String phrase) {
  if (s == phrase) return '';
  if (s.startsWith('$phrase ')) return s.substring(phrase.length + 1);
  return null;
}

/// The first phrase of [phrases] [s] starts with, and the rest.
(String, String)? _lead(String s, List<String> phrases) {
  for (final p in phrases) {
    final r = _after(s, p);
    if (r != null) return (p, r);
  }
  return null;
}

/// The original words of [alt] after its first words that normalize to
/// [phrase] (the spoken text keeps its case and accents).
String _rawRest(String alt, String phrase) {
  final words = alt.trim().split(RegExp(r'\s+'));
  for (var j = 1; j <= words.length; j++) {
    if (normalizeSpoken(words.take(j).join(' ')) == phrase) {
      return words.skip(j).join(' ').replaceFirst(RegExp(r'^[\s,.:;¿?¡!\-]+'), '').trim();
    }
  }
  return normalizeSpoken(alt).substring(phrase.length).trim();
}

(VoiceCommand, double) _parseOne(String alt, VoiceContext ctx) {
  final s = normalizeSpoken(alt);
  if (s.isEmpty) return (const UnknownCommand(), 0);

  if (_exit.contains(s)) return (const ExitCommand(), 1);
  if (_help.contains(s)) return (const HelpCommand(), 1);
  if (_repeat.contains(s)) return (const RepeatCommand(), 1);
  if (_stopExact.contains(s)) return (const StopCommand(), 1);
  if (_list.contains(s)) return (const ListAgentsCommand(), 1);
  if (_pending.contains(s) || (s.contains('pendiente') && s.split(' ').length <= 4)) return (const PendingCommand(), 1);

  // Free text: dictation and answers.
  if (_lead(s, _dictate) case (final p, _)) {
    final text = _rawRest(alt, p);
    return (DictateCommand(text.isEmpty ? null : text), 1);
  }
  if (_lead(s, _answer) case (final p, final rest)) {
    if (rest.isEmpty) return (const DictateCommand(), 1);
    final i = ctx.options.isEmpty ? null : matchSpokenOption(rest, ctx.options);
    if (i != null) return (AnswerCommand(ctx.options[i], option: i), 1);
    return (AnswerCommand(_rawRest(alt, p)), 1);
  }

  if (_lead(s, _launch) case (_, final rest)) {
    final l = _launchOf(rest, ctx);
    if (l != null) return (l, 1);
  }

  // Commands about one agent, which may be named after the keyword.
  for (final (phrases, make) in <(List<String>, VoiceCommand Function(String?))>[
    (_conclusion, (a) => ConclusionCommand(agent: a)),
    (_lastLines, (a) => LastLinesCommand(agent: a)),
    (_question, (a) => ReadQuestionCommand(agent: a)),
    (_stopPrefix, (a) => StopCommand(agent: a)),
  ]) {
    if (_lead(s, phrases) case (_, final rest)) {
      if (rest.isEmpty) return (make(null), 1);
      final m = _matchAgent(rest, ctx.agents);
      if (m case _AgentHit(:final keys) when keys.length == 1) return (make(keys.single), 0.95);
      // "para" also starts free phrases: only a named agent makes it a stop.
      if (identical(phrases, _stopPrefix)) continue;
      return (make(null), 0.5);
    }
  }

  // Options of the current agent ("opción dos", "la primera", "sí").
  final words = s.split(' ');
  final explicitAgent = words.first == 'agente' || (words.first == 'el' && words.length == 2);
  if (ctx.options.isNotEmpty && !explicitAgent) {
    final i = matchSpokenOption(alt, ctx.options);
    if (i != null) return (AnswerCommand(ctx.options[i], option: i), 0.8);
  }

  // An agent by number ("uno", "el dos", "agente tres").
  final rest = words.where((w) => !_fillers.contains(w)).toList();
  if (rest.length == 1) {
    final n = spokenNumber(rest.single);
    if (n != null && words.length <= 3) {
      if (n >= 1 && n <= ctx.agents.length) return (PickAgentCommand(ctx.agents[n - 1].key), 0.8);
      return (const UnknownCommand(), 0.1);
    }
  }

  if (ctx.options.isEmpty && _yesNo.contains(s)) return (AnswerCommand(alt.trim()), 0.6);

  // An agent by name or host ("api", "claude de webapp").
  if (_matchAgent(s, ctx.agents) case _AgentHit(:final keys, :final quality)) {
    if (keys.length == 1) return (PickAgentCommand(keys.single), 0.7 * quality);
    return (AmbiguousAgentCommand(keys), 0.65 * quality);
  }
  return (const UnknownCommand(), 0);
}

LaunchCommand? _launchOf(String rest, VoiceContext ctx) {
  var r = rest;
  String? harness;
  // "lanza codex en api", "nuevo claude en webapp".
  for (final e in _harnessAliases.entries) {
    if (_after(r, e.key) case final after?) {
      harness = e.value;
      r = after;
      break;
    }
  }
  // "... con codex"
  final con = r.lastIndexOf(RegExp(r'(^| )con '));
  if (con >= 0) {
    final h = r.substring(con).trim().substring(4).trim();
    harness ??= _harnessAliases[h] ?? _closestHarness(h);
    r = r.substring(0, con).trim();
  }
  // Without a project or a harness it is not a launch ("nuevo" alone).
  final p = r.split(' ').where((w) => !{'en', 'el', 'proyecto', 'para', 'de', 'agente', 'un', 'una'}.contains(w)).join(' ');
  if (p.isEmpty && harness == null && rest.isEmpty) return null;
  return LaunchCommand(project: _matchProject(r, ctx.projects), harness: harness ?? kVoiceHarnesses.first, heard: p);
}

String? _closestHarness(String h) {
  for (final e in _harnessAliases.entries) {
    if (_near(h.replaceAll(' ', ''), e.key.replaceAll(' ', ''))) return e.value;
  }
  return null;
}

/// The project named in [said] ("webapp", "web app de estudio", "en api en
/// vps"): the closest name; a host named after it breaks ties.
VoiceProject? _matchProject(String said, List<VoiceProject> projects) {
  final words = said.split(' ').where((w) => w.isNotEmpty && !{'en', 'el', 'proyecto', 'para', 'del', 'un', 'una'}.contains(w)).toList();
  if (words.isEmpty || projects.isEmpty) return null;
  VoiceProject? best;
  var bestScore = 0.0;
  for (final p in projects) {
    final name = normalizeSpoken(p.name);
    final host = normalizeSpoken(p.host);
    // Try every split: the first part is the project, the rest the host.
    for (var j = words.length; j >= 1; j--) {
      final part = words.take(j).where((w) => w != 'de').join(' ');
      final tail = words.skip(j).where((w) => w != 'de').join(' ');
      var score = _similarity(part, name);
      if (score == 0) continue;
      if (tail.isNotEmpty) {
        final h = _similarity(tail, host);
        if (h == 0) score *= 0.5;
        score += h * 0.1;
      }
      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }
  }
  return bestScore >= 0.5 ? best : null;
}

/// 1 for the same words (spaces ignored), less for a close word, 0 apart.
double _similarity(String said, String name) {
  final a = said.replaceAll(' ', '');
  final b = name.replaceAll(' ', '');
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  if (_near(a, b)) return 0.8;
  // A distinctive word of the name ("api" for "billing api").
  final nameWords = name.split(' ');
  if (nameWords.length > 1 && said.split(' ').every((w) => nameWords.any((n) => n == w || _near(w, n)))) return 0.6;
  return 0;
}

/// Edit distance at most 1 (2 for long words), for words of 4 letters or
/// more.
bool _near(String a, String b) {
  if (a.length < 4 || b.length < 4) return false;
  final max = a.length >= 8 && b.length >= 8 ? 2 : 1;
  if ((a.length - b.length).abs() > max) return false;
  return _distance(a, b) <= max;
}

int _distance(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}

class _AgentHit {
  const _AgentHit(this.keys, this.quality);
  final List<String> keys;
  final double quality;
}

/// The agents [said] names by its words ("api", "claude de webapp", "codex
/// en estudio"): every word must fit the agent's name or host; the agents
/// that fit the most words win.
_AgentHit? _matchAgent(String said, List<VoiceAgent> agents) {
  final words = said.split(' ').where((w) => w.isNotEmpty && !_fillers.contains(w)).toList();
  if (words.isEmpty) return null;
  final scores = <String, double>{};
  for (final a in agents) {
    final targets = {...normalizeSpoken(a.name).split(' '), ...normalizeSpoken(a.host).split(' ')}..remove('');
    final compact = {for (final t in targets) t, normalizeSpoken(a.name).replaceAll(' ', ''), normalizeSpoken(a.host).replaceAll(' ', '')};
    var total = 0.0;
    var ok = true;
    var i = 0;
    while (i < words.length) {
      final w = words[i];
      // "web app" for "webapp".
      if (i + 1 < words.length && compact.contains('$w${words[i + 1]}')) {
        total += 1;
        i += 2;
        continue;
      }
      if (compact.contains(w)) {
        total += 1;
      } else if (compact.any((t) => _near(w, t))) {
        total += 0.8;
      } else if (w.length >= 3 && compact.any((t) => t.startsWith(w))) {
        total += 0.6;
      } else {
        ok = false;
        break;
      }
      i++;
    }
    if (ok) scores[a.key] = total;
  }
  if (scores.isEmpty) return null;
  final top = scores.values.reduce((x, y) => x > y ? x : y);
  final keys = [for (final e in scores.entries) if (e.value == top) e.key];
  return _AgentHit(keys, (top / words.length).clamp(0, 1).toDouble());
}
