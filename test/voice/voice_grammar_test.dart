import 'package:agentd_app/src/voice/voice_grammar.dart';
import 'package:flutter_test/flutter_test.dart';

const _api = VoiceAgent(key: 'h1/agentd/codex@api', name: 'codex@api', host: 'estudio', hostId: 'h1');
const _web = VoiceAgent(key: 'h1/agentd/claude@webapp', name: 'claude@webapp', host: 'estudio', hostId: 'h1');
const _vpsApi = VoiceAgent(key: 'h2/agentd/codex@api', name: 'codex@api', host: 'vps', hostId: 'h2');

const _projects = [
  VoiceProject(name: 'webapp', hostId: 'h1', host: 'estudio'),
  VoiceProject(name: 'api', hostId: 'h1', host: 'estudio'),
  VoiceProject(name: 'api', hostId: 'h2', host: 'vps'),
  VoiceProject(name: 'docs', hostId: 'h1', host: 'estudio'),
];

const _ctx = VoiceContext(agents: [_api, _web], projects: _projects);
const _withOptions = VoiceContext(agents: [_api, _web], current: 'h1/agentd/codex@api', options: ['Migración en caliente', 'Ventana de mantenimiento'], projects: _projects);

VoiceCommand p(String said, [VoiceContext ctx = _ctx]) => parse([said], ctx);

void main() {
  test('simple commands, any case and accents', () {
    for (final s in ['agentes', 'Lista', '¿Qué agentes hay?', 'que agentes hay']) {
      expect(p(s), isA<ListAgentsCommand>(), reason: s);
    }
    for (final s in ['pendientes', '¿Qué espera?', 'Preguntas', 'qué hay pendiente']) {
      expect(p(s), isA<PendingCommand>(), reason: s);
    }
    for (final s in ['repite', 'Otra vez']) {
      expect(p(s), isA<RepeatCommand>(), reason: s);
    }
    for (final s in ['ayuda', '¿Qué puedo decir?']) {
      expect(p(s), isA<HelpCommand>(), reason: s);
    }
    for (final s in ['salir', 'Termina', 'Adiós']) {
      expect(p(s), isA<ExitCommand>(), reason: s);
    }
    for (final s in ['para', 'Detén', 'escape', 'stop']) {
      expect(p(s), isA<StopCommand>().having((c) => c.agent, 'agent', isNull), reason: s);
    }
  });

  test('commands about an agent, optionally named', () {
    expect(p('conclusión'), isA<ConclusionCommand>().having((c) => c.agent, 'agent', isNull));
    expect(p('¿Qué ha dicho?'), isA<ConclusionCommand>());
    expect(p('resumen'), isA<ConclusionCommand>());
    expect(p('final'), isA<ConclusionCommand>());
    expect(p('qué ha dicho api'), isA<ConclusionCommand>().having((c) => c.agent, 'agent', _api.key));
    expect(p('últimas líneas'), isA<LastLinesCommand>());
    expect(p('¿Qué está haciendo claude?'), isA<LastLinesCommand>().having((c) => c.agent, 'agent', _web.key));
    expect(p('pregunta'), isA<ReadQuestionCommand>());
    expect(p('opciones'), isA<ReadQuestionCommand>());
    expect(p('para api'), isA<StopCommand>().having((c) => c.agent, 'agent', _api.key));
  });

  test('pick an agent by number', () {
    expect(p('uno'), isA<PickAgentCommand>().having((c) => c.key, 'key', _api.key));
    expect(p('el dos'), isA<PickAgentCommand>().having((c) => c.key, 'key', _web.key));
    expect(p('agente 2'), isA<PickAgentCommand>().having((c) => c.key, 'key', _web.key));
    expect(p('Agente tres'), isA<UnknownCommand>());
    // With options open, "el dos" and "agente dos" are still agents.
    expect(p('el dos', _withOptions), isA<PickAgentCommand>());
    expect(p('agente uno', _withOptions), isA<PickAgentCommand>());
  });

  test('pick an agent by name or host, fuzzy', () {
    expect(p('api'), isA<PickAgentCommand>().having((c) => c.key, 'key', _api.key));
    expect(p('claude de webapp'), isA<PickAgentCommand>().having((c) => c.key, 'key', _web.key));
    expect(p('Claude de web app'), isA<PickAgentCommand>().having((c) => c.key, 'key', _web.key));
    expect(p('webap'), isA<PickAgentCommand>().having((c) => c.key, 'key', _web.key));
    expect(p('codex'), isA<PickAgentCommand>().having((c) => c.key, 'key', _api.key));
    expect(p('patata frita'), isA<UnknownCommand>());
  });

  test('a name on two hosts is ambiguous until the host is said', () {
    const ctx = VoiceContext(agents: [_api, _web, _vpsApi]);
    expect(p('api', ctx), isA<AmbiguousAgentCommand>().having((c) => c.keys, 'keys', [_api.key, _vpsApi.key]));
    expect(p('api en vps', ctx), isA<PickAgentCommand>().having((c) => c.key, 'key', _vpsApi.key));
    expect(p('codex de estudio', ctx), isA<PickAgentCommand>().having((c) => c.key, 'key', _api.key));
  });

  test('answers name an option of the current agent', () {
    expect(p('opción dos', _withOptions), isA<AnswerCommand>().having((c) => c.option, 'option', 1).having((c) => c.text, 'text', 'Ventana de mantenimiento'));
    expect(p('la primera', _withOptions), isA<AnswerCommand>().having((c) => c.option, 'option', 0));
    expect(p('dos', _withOptions), isA<AnswerCommand>().having((c) => c.option, 'option', 1));
    expect(p('responde la segunda', _withOptions), isA<AnswerCommand>().having((c) => c.option, 'option', 1));
    expect(p('Responde: espera a mañana', _withOptions), isA<AnswerCommand>().having((c) => c.option, 'option', isNull).having((c) => c.text, 'text', 'espera a mañana'));
    const yesNo = VoiceContext(agents: [_web], current: 'h1/agentd/claude@webapp', options: ['Yes', 'No']);
    expect(p('sí', yesNo), isA<AnswerCommand>().having((c) => c.text, 'text', 'Yes'));
    expect(p('no', yesNo), isA<AnswerCommand>().having((c) => c.text, 'text', 'No'));
  });

  test('yes / no without options are answers in the words said', () {
    expect(p('Sí'), isA<AnswerCommand>().having((c) => c.text, 'text', 'Sí').having((c) => c.option, 'option', isNull));
    expect(p('responde'), isA<DictateCommand>().having((c) => c.text, 'text', isNull));
  });

  test('dictation keeps the words as said', () {
    expect(p('dicta'), isA<DictateCommand>().having((c) => c.text, 'text', isNull));
    expect(p('Instrucción'), isA<DictateCommand>().having((c) => c.text, 'text', isNull));
    expect(p('Escribe: Añade tests al módulo de pagos'), isA<DictateCommand>().having((c) => c.text, 'text', 'Añade tests al módulo de pagos'));
    expect(p('dicta revisa el README'), isA<DictateCommand>().having((c) => c.text, 'text', 'revisa el README'));
    expect(p('nueva instrucción haz commit'), isA<DictateCommand>().having((c) => c.text, 'text', 'haz commit'));
  });

  test('launch picks the project and the harness', () {
    expect(p('nuevo agente en webapp'), isA<LaunchCommand>().having((c) => c.project?.name, 'project', 'webapp').having((c) => c.harness, 'harness', 'claude'));
    expect(p('Nuevo agente en web app con codex'), isA<LaunchCommand>().having((c) => c.project?.name, 'project', 'webapp').having((c) => c.harness, 'harness', 'codex'));
    expect(p('lanza pando en docs'), isA<LaunchCommand>().having((c) => c.project?.name, 'project', 'docs').having((c) => c.harness, 'harness', 'pando'));
    expect(p('nuevo agente en api de vps con cloud'), isA<LaunchCommand>().having((c) => c.project?.hostId, 'host', 'h2').having((c) => c.harness, 'harness', 'claude'));
    expect(p('nuevo agente en api'), isA<LaunchCommand>().having((c) => c.project?.hostId, 'host', 'h1'));
    expect(p('nuevo agente en zanahoria'), isA<LaunchCommand>().having((c) => c.project, 'project', isNull).having((c) => c.heard, 'heard', 'zanahoria'));
  });

  test('the best alternative wins, the first on a tie', () {
    expect(parse(['agente es', 'agentes'], _ctx), isA<ListAgentsCommand>());
    expect(parse(['patata', 'conclusión', 'pendientes'], _ctx), isA<ConclusionCommand>());
    expect(parse(['hola que tal', 'api'], _ctx), isA<PickAgentCommand>());
    expect(parse(['', '  '], _ctx), isA<UnknownCommand>());
    expect(parse(const [], _ctx), isA<UnknownCommand>());
  });

  group('parseConfirm', () {
    test('yes, no, again', () {
      for (final s in ['sí', 'Sí, envía', 'envía', 'vale', 'adelante', 'Seguro']) {
        expect(parseConfirm([s]), VoiceConfirm.yes, reason: s);
      }
      for (final s in ['no', 'cancela', 'No, déjalo', 'olvídalo']) {
        expect(parseConfirm([s]), VoiceConfirm.no, reason: s);
      }
      for (final s in ['repite', 'otra vez', 'corrige']) {
        expect(parseConfirm([s]), VoiceConfirm.redo, reason: s);
      }
      expect(parseConfirm(['sí pero cambia el nombre']), VoiceConfirm.unknown);
      expect(parseConfirm(['patata']), VoiceConfirm.unknown);
    });

    test('a doubt between yes and no sends nothing', () {
      expect(parseConfirm(['sí', 'no']), VoiceConfirm.unknown);
      expect(parseConfirm(['patata', 'sí']), VoiceConfirm.yes);
    });
  });
}
