import 'dart:async';

import 'package:agentd_app/src/agentd/client.dart';
import 'package:agentd_app/src/agentd/errors.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_daemon.dart';

void main() {
  late FakeDaemon d;
  late AgentdClient c;

  setUp(() {
    d = FakeDaemon(serverChunk: 3); // answers arrive in 3-byte pieces
    c = AgentdClient(d.dial, timeout: const Duration(seconds: 2));
  });

  test('one connection per request, closed after the answer', () async {
    d.answer('ping', {'version': '0.4.0', 'pid': 12, 'epoch': 'ep1'});
    final p = await c.ping();
    expect((p.version, p.pid, p.epoch), ('0.4.0', 12, 'ep1'));
    await c.ping();
    expect(d.dials, 2);
    expect(d.requests.first, {'op': 'ping'});
    expect(d.clientEnds.every((e) => e.isClosed), isTrue);
  });

  test('info', () async {
    d.answer('info', {
      'host': 'box',
      'version': '1',
      'pid': 1,
      'epoch': 'e',
      'harnesses': ['claude', 'codex'],
      'profiles': [
        {'name': 'claude', 'builtin': true, 'cols': 160, 'rows': 50},
      ],
      'aliases': [
        {'name': 'webapp', 'dir': '/src/webapp', 'source': 'file'},
      ],
      'agent_view': false,
    });
    final i = await c.info();
    expect(i.host, 'box');
    expect(i.harnesses, ['claude', 'codex']);
    expect(i.profiles.single.cols, 160);
    expect(i.aliases.single.dir, '/src/webapp');
  });

  test('ls parses SessionInfo', () async {
    d.answer('ls', {
      'sessions': [sessionInfoJson(status: 'waiting', attention: true)],
    });
    final s = (await c.ls()).single;
    expect(s.name, 'claude@webapp');
    expect(s.status, 'waiting');
    expect(s.attention, isTrue);
    expect(s.turn, 3);
    expect(s.startedAt, DateTime.utc(2026, 11, 15, 10, 0, 0, 123, 456));
    expect(s.lastOutput, DateTime.utc(2026, 11, 15, 10, 5, 0, 500));
  });

  test('view args and not_modified', () async {
    d.answer('view', {'not_modified': true, 'epoch': 'ep1', 'revision': 9});
    final v = await c.view('claude@webapp', sinceRevision: 9, epoch: 'ep1', linesLimit: 100);
    expect(d.lastArgs('view'), {'name': 'claude@webapp', 'since_revision': 9, 'epoch': 'ep1', 'lines_limit': 100});
    expect(v.notModified, isTrue);
    expect(v.name, 'claude@webapp');
    expect(v.revision, 9);

    d.answer('view', viewJson());
    final full = await c.view('claude@webapp');
    expect(d.lastArgs('view'), {'name': 'claude@webapp'});
    expect(full.options.map((o) => o.id), ['o1', 'o2']);
    expect(full.dialogQuestion, 'Do you want to proceed?');
    expect(full.input.ghost, 'Try "fix tests"');
    expect(full.attention.reason, 'waiting');
  });

  test('view markup: an old daemon that rejects it gets plain, escaped text', () async {
    var calls = 0;
    d.on('view', (q) {
      calls++;
      if (q.args.containsKey('markup')) {
        q.fail('invalid view args: json: unknown field "markup"', code: 'invalid');
        return;
      }
      q.ok({
        ...viewJson(),
        'lines': [
          {'text': 'a *b* `c`', 'role': 'transcript'},
        ],
      });
    });
    final v = await c.view('s', markup: true);
    expect(v.lines.single.markup, r'a \*b\* \`c\`');
    expect(calls, 2);
    await c.view('s', markup: true);
    expect(calls, 3, reason: 'remembered: no second refused call');
  });

  test('act prompt / choose / keys / interrupt / cancel args', () async {
    d.answer('act', {'revision': 10, 'status': 'working', 'result': 'submitted', 'submitted': true});
    final r = await c.prompt('s', 'hello', revision: 9, epoch: 'ep1');
    expect(r.result, 'submitted');
    expect(r.submitted, isTrue);
    expect(d.lastArgs('act'), {'name': 's', 'action': 'prompt', 'text': 'hello', 'revision': 9, 'epoch': 'ep1', 'client': 'agentd-app'});

    await c.prompt('s', 'draft', submit: false, force: true);
    expect(d.lastArgs('act'), {'name': 's', 'action': 'prompt', 'text': 'draft', 'submit': false, 'client': 'agentd-app', 'force': true});

    await c.choose('s', 'o1', label: 'Yes', revision: 9, epoch: 'ep1');
    expect(d.lastArgs('act'), {
      'name': 's',
      'action': 'choose',
      'option_id': 'o1',
      'label': 'Yes',
      'revision': 9,
      'epoch': 'ep1',
      'client': 'agentd-app',
    });

    await c.keys('s', ['esc', 'enter']);
    expect(d.lastArgs('act'), {
      'name': 's',
      'action': 'keys',
      'keys': ['esc', 'enter'],
      'client': 'agentd-app',
    });

    await c.interrupt('s', force: true);
    expect(d.lastArgs('act'), {'name': 's', 'action': 'interrupt', 'client': 'agentd-app', 'force': true});

    await c.cancel('s');
    expect(d.lastArgs('act'), {'name': 's', 'action': 'cancel', 'client': 'agentd-app'});
  });

  test('act conflict carries the fresh view', () async {
    d.on('act', (k) => k.fail('menu changed', code: 'conflict', data: {'revision': 11, 'view': viewJson(revision: 11)}));
    try {
      await c.choose('s', 'o1', revision: 9, epoch: 'ep1');
      fail('no error');
    } on AgentdError catch (e) {
      expect(e.code, AgentdErrorCode.conflict);
      expect(AgentdClient.conflictView(e)!.revision, 11);
    }
  });

  test('error codes surface as AgentdError', () async {
    for (final code in ['busy', 'not_ready', 'not_found', 'forbidden', 'verify_failed', 'starting']) {
      d.on('act', (k) => k.fail('nope', code: code));
      await expectLater(c.interrupt('s'), throwsA(isA<AgentdError>().having((e) => e.code, 'code', code)));
    }
    expect(const AgentdError('x', code: 'busy').isRetryable, isTrue);
  });

  test('run / kill / rm args', () async {
    d.answer('run', sessionInfoJson(name: 'codex@api', state: 'running', status: null));
    final s = await c.run(target: 'api', harness: 'codex', cols: 120, rows: 40);
    expect(s.name, 'codex@api');
    expect(d.lastArgs('run'), {'name': '', 'target': 'api', 'harness': 'codex', 'cols': 120, 'rows': 40});

    await c.run(target: '/srv/x', harness: 'claude', name: 'claude@x', cwd: '/srv', labels: {'k': 'v'});
    expect(d.lastArgs('run'), {
      'name': 'claude@x',
      'target': '/srv/x',
      'harness': 'claude',
      'cwd': '/srv',
      'labels': {'k': 'v'},
    });

    d.answer('kill', null);
    await c.kill('s');
    expect(d.lastArgs('kill'), {'name': 's'});
    await c.kill('s', signal: 'HUP');
    expect(d.lastArgs('kill'), {'name': 's', 'signal': 'HUP'});

    d.answer('rm', null);
    await c.rm('s');
    expect(d.lastArgs('rm'), {'name': 's'});
  });

  test('mailbox ops', () async {
    d.answer('send', messageJson(id: 9));
    final m = await c.send(to: 'codex@api', body: 'hi');
    expect(m.id, 9);
    expect(d.lastArgs('send'), {'to': 'codex@api', 'body': 'hi'});
    await c.send(to: 'queue:review', subject: 's', body: 'b', replyTo: 3);
    expect(d.lastArgs('send'), {'to': 'queue:review', 'subject': 's', 'body': 'b', 'reply_to': 3});

    d.answer('inbox', {
      'messages': [messageJson()],
      'digest': 'd0123456789abcdef',
    });
    final ib = await c.inbox(all: true);
    expect(d.lastArgs('inbox'), {'all': true});
    expect(ib.messages.single.sender, 'codex@api');
    expect(ib.digest, 'd0123456789abcdef');

    d.answer('inbox', {'messages': [], 'digest': 'd0', 'not_modified': true});
    expect((await c.inbox(sinceDigest: 'd0')).notModified, isTrue);
    expect(d.lastArgs('inbox'), {'since_digest': 'd0'});

    d.answer('read', messageJson(state: 'read'));
    expect((await c.read(5)).state, 'read');
    expect(d.lastArgs('read'), {'id': 5});

    d.answer('reply', messageJson(id: 6));
    await c.reply(5, 'ok');
    expect(d.lastArgs('reply'), {'id': 5, 'body': 'ok'});

    d.answer('queue', {
      'queues': [
        {'name': 'review', 'unclaimed': 2},
      ],
    });
    final q = await c.queue();
    expect(q.queues.single.unclaimed, 2);
    expect(d.lastArgs('queue'), isEmpty);

    d.answer('queue', {
      'name': 'review',
      'items': [messageJson(state: 'unclaimed', queue: 'review')],
      'digest': 'dx',
    });
    final items = await c.queue(name: 'review');
    expect(items.items.single.queue, 'review');
    expect(d.lastArgs('queue'), {'name': 'review'});
  });

  test('turns and label', () async {
    d.answer('turns', {
      'turns': [
        {
          'turn': 1,
          'outcome': 'completed',
          'origin': 'act',
          'status': 'idle',
          'message': 'Done',
          'started_at': '2026-11-15T10:00:00Z',
          'ended_at': '2026-11-15T10:01:00Z',
        },
      ],
    });
    final t = (await c.turns('s')).single;
    expect((t.turn, t.outcome, t.origin), (1, 'completed', 'act'));
    expect(d.lastArgs('turns'), {'name': 's'});

    d.answer('label', {
      'labels': {'a': '1'},
    });
    expect(await c.label('s', {'a': '1', 'b': ''}), {'a': '1'});
    expect(d.lastArgs('label'), {
      'name': 's',
      'labels': {'a': '1', 'b': ''},
    });
  });

  test('connection closed before the answer', () async {
    d.on('ping', (k) {});
    await expectLater(c.ping(), throwsA(isA<AgentdTransportError>()));
  });

  test('no answer times out', () async {
    d.keepOpen.add('ping');
    d.on('ping', (k) {});
    final slow = AgentdClient(d.dial, timeout: const Duration(milliseconds: 100));
    await expectLater(slow.ping(), throwsA(isA<AgentdTransportError>()));
    expect(d.clientEnds.last.isClosed, isTrue);
  });

  test('dial failure is a transport error', () async {
    d.dialError = StateError('no route');
    await expectLater(c.ping(), throwsA(isA<AgentdTransportError>()));
  });

  test('unknown op answer from the daemon', () async {
    await expectLater(c.call('nope'), throwsA(isA<AgentdError>().having((e) => e.code, 'code', 'invalid')));
  });

  test('concurrent requests use separate connections', () async {
    final gate = Completer<void>();
    d.on('ls', (k) async {
      await gate.future;
      k.ok({'sessions': []});
    });
    d.answer('ping', {'version': 'v', 'pid': 1, 'epoch': 'e'});
    final ls = c.ls();
    await c.ping();
    gate.complete();
    expect(await ls, isEmpty);
  });
}
