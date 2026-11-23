import 'package:agentd_app/src/agentd/mapping.dart';
import 'package:agentd_app/src/agentd/models.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_daemon.dart';

void main() {
  test('status mapping', () {
    expect(mapStatus('working'), AgentStatus.working);
    expect(mapStatus('waiting'), AgentStatus.waiting);
    expect(mapStatus('idle'), AgentStatus.idle);
    expect(mapStatus('starting'), AgentStatus.starting);
    expect(mapStatus('exited'), AgentStatus.exited);
    expect(mapStatus(null, state: 'starting'), AgentStatus.starting);
    expect(mapStatus(null, state: 'exited'), AgentStatus.exited);
    expect(mapStatus(null, state: 'running'), AgentStatus.unknown);
  });

  test('SessionInfo → AgentSession', () {
    final s = toAgentSession(AgentdSessionInfo.fromJson(sessionInfoJson(status: 'waiting', attention: true)), hostId: 'h1');
    expect(s.key, 'h1/agentd/claude@webapp');
    expect((s.harness, s.project), ('claude', 'webapp'));
    expect(s.status, AgentStatus.waiting);
    expect(s.attention, isTrue);
    expect(s.preview, 'Done.');
    expect(s.turn, 3);
    expect(s.cwd, '/home/u/src/webapp');
    expect(s.updatedAt, DateTime.utc(2026, 11, 15, 10, 5, 0, 500));
  });

  test('labels win over the name; fallbacks to profile and cwd', () {
    final l = toAgentSession(
      AgentdSessionInfo.fromJson(sessionInfoJson(name: 'x@y', labels: {'agentd.harness': 'codex', 'herdr.space': 'api'})),
      hostId: 'h',
    );
    expect((l.harness, l.project), ('codex', 'api'));
    final plain = toAgentSession(AgentdSessionInfo.fromJson(sessionInfoJson(name: 'worker')), hostId: 'h');
    expect((plain.harness, plain.project), ('claude', 'webapp'));
  });

  test('View → SessionView with pending interaction and chat items', () {
    final base = toAgentSession(AgentdSessionInfo.fromJson(sessionInfoJson()), hostId: 'h');
    final v = toSessionView(AgentdView.fromJson(viewJson()), base);
    expect(v.revision, 9);
    expect(v.epoch, 'ep1');
    expect(v.ghost, 'Try "fix tests"');
    expect(v.inputText, '');
    expect(v.session.status, AgentStatus.waiting);
    expect(v.session.attention, isTrue);
    final p = v.session.pending!;
    expect(p.question, 'Do you want to proceed?');
    expect(p.revision, 9);
    expect(p.epoch, 'ep1');
    expect(p.options.map((o) => (o.id, o.label, o.index, o.selected)), [('o1', 'Yes', 1, true), ('o2', 'No', 2, false)]);
    expect(p.options.map((o) => o.kind), [OptionKind.numbered, OptionKind.numbered]);
    expect(p.kind, PendingKind.permission);

    final items = v.items;
    expect(items.map((i) => i.role), [ChatRole.user, ChatRole.agent, ChatRole.tool, ChatRole.system]);
    expect(items[0].text, 'fix the lint errors');
    expect(items[1].text, 'I will run the linter first.');
    expect(items[2].title, 'Bash');
    expect(items[2].text, 'npm run lint\n3 errors found\nsrc/a.ts:1');
    expect(items[2].meta, '3 errors found');
    expect(items[1].meta, isNull);
  });

  test('idle view without dialog has no pending', () {
    final base = toAgentSession(AgentdSessionInfo.fromJson(sessionInfoJson()), hostId: 'h');
    final j = viewJson(status: 'idle')
      ..remove('dialog')
      ..['options'] = [];
    expect(toSessionView(AgentdView.fromJson(j), base).session.pending, isNull);
  });

  test('codex transcript and box borders', () {
    final items = chatItemsFromLines(const [
      AgentdViewLine('╭──────────╮', 'transcript'),
      AgentdViewLine('› add a test', 'transcript'),
      AgentdViewLine('• Ran go test ./...', 'transcript'),
      AgentdViewLine('  └ ok', 'transcript'),
      AgentdViewLine('• All tests pass.', 'transcript'),
      AgentdViewLine('  Second line.', 'transcript'),
    ]);
    expect(items.map((i) => (i.role, i.title)), [(ChatRole.user, null), (ChatRole.tool, 'Ran'), (ChatRole.agent, null)]);
    expect(items[2].text, 'All tests pass.\nSecond line.');
  });

  group('pending classification', () {
    AgentdViewOption opt(String id, String label, {String kind = 'numbered', bool? checked}) =>
        AgentdViewOption(id: id, label: label, index: int.parse(id.substring(1)), kind: kind, checked: checked);

    test('Claude Code Bash permission: header question, command as detail', () {
      final c = classifyPending(
        question: 'Bash command',
        dialogLines: const ['│ Bash command                      │', '│                                   │', '│   go test ./internal/... -race    │', '│   Run the tests                   │', '│ Do you want to proceed?           │', '│ ❯ 1. Yes                          │'],
        options: [opt('o1', 'Yes'), opt('o2', "Yes, and don't ask again for go test commands"), opt('o3', 'No, and tell Claude what to do differently (esc)')],
      );
      expect(c.kind, PendingKind.permission);
      expect(c.detail, 'go test ./internal/... -race');
      expect(c.question, 'Do you want to proceed?');
    });

    test('Codex command approval', () {
      final c = classifyPending(
        question: 'Would you like to run the following command?\n\$ git status --short',
        options: [opt('o1', 'Yes, proceed (y)'), opt('o2', "Yes, and don't ask again for this command (a)"), opt('o3', 'No, and tell Codex what to do differently (esc)')],
      );
      expect(c.kind, PendingKind.permission);
      expect(c.detail, 'git status --short');
      expect(c.question, 'Would you like to run the following command?');
    });

    test('edit permission without a command line', () {
      final c = classifyPending(question: 'Do you want to make this edit to main.go?', options: [opt('o1', 'Yes'), opt('o2', 'No')]);
      expect(c.kind, PendingKind.permission);
      expect(c.detail, isNull);
    });

    test('plan approval', () {
      final c = classifyPending(
        question: 'Would you like to proceed?',
        dialogLines: const ['Ready to code?', "Here is Claude's plan:"],
        options: [opt('o1', 'Yes, and auto-accept edits'), opt('o2', 'Yes, and manually approve edits'), opt('o3', 'No, keep planning')],
      );
      expect(c.kind, PendingKind.plan);
    });

    test('a question with options', () {
      final c = classifyPending(question: '¿Qué base de datos uso?', options: [opt('o1', 'Postgres'), opt('o2', 'SQLite')]);
      expect(c.kind, PendingKind.question);
      expect(c.detail, isNull);
      expect(c.question, '¿Qué base de datos uso?');
    });

    test('nothing on screen is unknown; a reported OSC 7501 kind wins', () {
      expect(classifyPending(question: '').kind, PendingKind.unknown);
      expect(classifyPending(question: 'Do you want to proceed?', options: [opt('o1', 'Yes')], reportedKind: 'question').kind, PendingKind.question);
      expect(classifyPending(question: 'Pick one', reportedKind: 'permission').kind, PendingKind.permission);
    });

    test('checkbox options keep their state', () {
      final j = viewJson()
        ..['options'] = [
          {'id': 'c1', 'label': 'lint', 'index': 1, 'kind': 'checkbox', 'checked': true},
          {'id': 'c2', 'label': 'tests', 'index': 2, 'kind': 'checkbox', 'checked': false},
          {'id': 'c3', 'label': 'Submit', 'index': 3, 'kind': 'pointer'},
        ];
      final p = pendingOf(AgentdView.fromJson(j))!;
      expect(p.options.map((o) => (o.kind, o.checked)), [(OptionKind.checkbox, true), (OptionKind.checkbox, false), (OptionKind.pointer, null)]);
    });
  });

  test('codex tool output lines give the meta', () {
    final items = chatItemsFromLines(const [
      AgentdViewLine('• Ran go test ./...', 'transcript'),
      AgentdViewLine('  └ ok  github.com/x/y  0.4s', 'transcript'),
    ]);
    expect(items.single.title, 'Ran');
    expect(items.single.meta, 'ok  github.com/x/y  0.4s');
  });

  test('agent text uses the chat markup; tools stay plain', () {
    final items = chatItemsFromLines(const [
      AgentdViewLine('● No por ahora. Chunking', 'transcript', md: '● **No por ahora.** Chunking'),
      AgentdViewLine('', 'transcript'),
      AgentdViewLine('  Antes de RAG', 'transcript', md: '  ### Antes de RAG'),
      AgentdViewLine('  - usa grant_call_id', 'transcript', md: '  - usa `grant_call_id`'),
      AgentdViewLine('● Bash(ls *.go)', 'transcript'),
    ]);
    expect(items.first.role, ChatRole.agent);
    expect(items.first.text, '**No por ahora.** Chunking\n\n### Antes de RAG\n- usa `grant_call_id`');
    expect(items.last.role, ChatRole.tool);
    expect(AgentdViewLine.fromJson({'text': 'a', 'role': 'transcript', 'md': '**a**'}).markup, '**a**');
    expect(const AgentdViewLine('a*b', 'transcript').markup, 'a*b');
  });

  // The cases of agentd's TestItemsGroupMultiLineToolCalls.
  test('multi-line, bare and MCP tool calls are grouped in tool items', () {
    final items = chatItemsFromLines(const [
      AgentdViewLine('● Miro el estado.', 'transcript'),
      AgentdViewLine('', 'transcript'),
      AgentdViewLine("● Bash(agentd task set <<'EOF'", 'transcript', md: r"● **Bash**(agentd task set \<\<'EOF'"),
      AgentdViewLine('  [', 'transcript', md: r'  \['),
      AgentdViewLine('', 'transcript'),
      AgentdViewLine('   {"id":"a"}', 'transcript'),
      AgentdViewLine('  EOF)', 'transcript'),
      AgentdViewLine('  ⎿  revision 2', 'transcript'),
      AgentdViewLine('     second line', 'transcript'),
      AgentdViewLine('', 'transcript'),
      AgentdViewLine('● Read', 'transcript', md: '● **Read**'),
      AgentdViewLine('', 'transcript'),
      AgentdViewLine('● agentd - agentd_inbox (MCP)(all: true)', 'transcript', md: r'● **agentd - agentd\_inbox (MCP)**(all: true)'),
      AgentdViewLine('● Listo', 'transcript'),
      AgentdViewLine('✻ Brewed for 8s · done 15:16', 'transcript'),
    ]);
    expect(items.map((i) => i.role), [ChatRole.agent, ChatRole.tool, ChatRole.tool, ChatRole.tool, ChatRole.agent, ChatRole.system]);
    final bash = items[1];
    expect(bash.title, 'Bash');
    // The whole call, then its output; nothing leaks into the prose.
    expect(bash.text, "agentd task set <<'EOF'\n[\n {\"id\":\"a\"}\nEOF)\nrevision 2\nsecond line");
    expect(bash.meta, 'revision 2');
    expect((items[2].title, items[2].text), ('Read', ''));
    expect((items[3].title, items[3].text), ('agentd - agentd_inbox (MCP)', 'all: true'));
    expect(items[4].text, 'Listo');
    expect(items[5].text, '✻ Brewed for 8s · done 15:16');
  });

  test('without markup, an unclosed call still opens a tool item', () {
    final items = chatItemsFromLines(const [
      AgentdViewLine("● Bash(cat <<'EOF'", 'transcript'),
      AgentdViewLine('  hola', 'transcript'),
      AgentdViewLine('  EOF)', 'transcript'),
      AgentdViewLine('  ⎿  hola', 'transcript'),
      AgentdViewLine('● Read(a.go)', 'transcript'),
    ]);
    expect(items.map((i) => (i.role, i.title)), [(ChatRole.tool, 'Bash'), (ChatRole.tool, 'Read')]);
    expect(items[0].text, "cat <<'EOF'\nhola\nEOF)\nhola");
    expect(items[1].text, 'a.go');
  });

  // The cases of agentd's TestItemsFenceCodeAndJoinPrompt.
  test('code lines become one fenced block; a prompt of several lines is one item', () {
    final items = chatItemsFromLines(const [
      AgentdViewLine('❯ primera línea', 'transcript'),
      AgentdViewLine('  segunda línea', 'transcript'),
      AgentdViewLine('● Instálalo así:', 'transcript'),
      AgentdViewLine('', 'transcript'),
      AgentdViewLine('  func main() {', 'transcript', code: true),
      AgentdViewLine('', 'transcript'),
      AgentdViewLine('      run("a_b")', 'transcript', code: true),
      AgentdViewLine('  }', 'transcript'),
      AgentdViewLine('', 'transcript'),
      AgentdViewLine('  Y reinicia `agentd`.', 'transcript', md: r'  Y reinicia \`agentd\`.'),
      AgentdViewLine('● sudo dpkg -i a.deb', 'transcript', code: true),
    ]);
    expect(items.map((i) => i.role), [ChatRole.user, ChatRole.agent, ChatRole.agent]);
    expect(items[0].text, 'primera línea\nsegunda línea');
    expect(items[1].text, 'Instálalo así:\n\n````\nfunc main() {\n\n    run("a_b")\n}\n````\n\nY reinicia \\`agentd\\`.');
    expect(items[2].text, '````\nsudo dpkg -i a.deb\n````');
  });

  test('a daemon without code lines gives no code blocks', () {
    expect(AgentdViewLine.fromJson({'text': 'x := 1', 'role': 'transcript'}).code, isFalse);
    expect(AgentdViewLine.fromJson({'text': 'x := 1', 'role': 'transcript', 'code': true}).code, isTrue);
    final items = chatItemsFromLines(const [AgentdViewLine('● Así:', 'transcript'), AgentdViewLine('', 'transcript'), AgentdViewLine('  x := 1', 'transcript')]);
    expect(items.single.text, 'Así:\n\nx := 1');
  });

  test('mail and queues', () {
    final m = toMailMessage(AgentdMessage.fromJson(messageJson(state: 'unclaimed', queue: 'review')));
    expect((m.id, m.from, m.to, m.state, m.queue), (5, 'codex@api', 'queue:review', MailState.unclaimed, 'review'));
    expect(m.createdAt, DateTime.utc(2026, 11, 15, 9));
    final q = toWorkQueue(const AgentdQueueCount('review', 2));
    expect((q.name, q.unclaimed), ('review', 2));
  });

  test('Go zero time is null', () {
    expect(parseGoTime('0001-01-01T00:00:00Z'), isNull);
    expect(parseGoTime(null), isNull);
  });
}
