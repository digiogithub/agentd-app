// Work dashboard wire: ops board / tasks, question fields of messages,
// task.changed and the task summary of SessionInfo.

import 'package:agentd_app/src/agentd/agentd.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_daemon.dart';

void main() {
  late FakeDaemon d;
  late AgentdClient c;

  setUp(() {
    d = FakeDaemon(serverChunk: 7);
    c = AgentdClient(d.dial, timeout: const Duration(seconds: 2));
  });

  test('board: sessions with tasks and questions, conditional on the digest', () async {
    d.on('board', (conn) {
      if (conn.args['since_digest'] == 'b1') return conn.ok({'digest': 'b1', 'not_modified': true});
      conn.ok(boardJson());
    });
    final b = await c.board();
    expect(d.requests.single['op'], 'board');
    expect(d.lastArgs('board'), isEmpty);
    expect((b.digest, b.unreadHuman, b.notModified), ('b1', 2, false));
    final s = b.sessions.first;
    expect((s.name, s.status, s.turn, s.preview), ('claude@webapp', 'working', 3, 'Running the tests'));
    expect(s.tasks.map((t) => '${t.id}:${t.status}'), ['t1:done', 't2:in_progress', 't3:blocked', 't4:pending', 't5:cancelled']);
    expect(s.tasks[2].note, 'Missing credential');
    expect(s.tasks.first.updatedAt, DateTime.utc(2026, 11, 22, 9));
    final q = s.questions.single;
    expect((q.id, q.body, q.task), (21, 'Schema v4 in this change?', 't2'));
    expect(q.options, ['Same change', 'Separate']);
    expect(b.sessions.last.tasks, isEmpty);

    final again = await c.board(sinceDigest: 'b1');
    expect(d.lastArgs('board'), {'since_digest': 'b1'});
    expect(again.notModified, isTrue);
    expect(again.sessions, isEmpty);
  });

  test('board maps to the contracts', () {
    final b = toHostBoard(AgentdBoard.fromJson(boardJson()), hostId: 'h');
    final s = b.sessions.first;
    expect((b.hostId, b.unreadHuman, b.available), ('h', 2, true));
    expect(s.key, 'h/agentd/claude@webapp');
    expect(s.status, AgentStatus.working);
    expect((s.done, s.total), (1, 4), reason: 'cancelled tasks do not count');
    expect(s.current!.title, 'Persist tasks');
    expect(s.count(TaskStatus.blocked), 1);
    expect(s.questions.single.taskId, 't2');
    expect(mapTaskStatus('whatever'), TaskStatus.pending);
  });

  test('tasks reads one list', () async {
    d.answer('tasks', {
      'name': 'claude@webapp',
      'tasks': [taskJson('t1', 'Task model', status: 'done'), {'id': 't2', 'title': 'No status'}],
      'revision': 4,
    });
    final r = await c.tasks('claude@webapp');
    expect(d.lastArgs('tasks'), {'name': 'claude@webapp'});
    expect((r.name, r.revision, r.tasks.length), ('claude@webapp', 4, 2));
    expect(r.tasks.last.status, 'pending');
  });

  test('messages carry the question fields; reply answers one', () async {
    d.answer('reply', {...messageJson(id: 30), 'reply_to': 21});
    final m = await c.reply(21, 'Same change');
    expect(d.lastArgs('reply'), {'id': 21, 'body': 'Same change'});
    expect((m.replyTo, m.isQuestion), (21, false));

    final q = AgentdMessage.fromJson({...messageJson(id: 21), 'kind': 'question', 'options': ['A', 'B'], 'task': 't2'});
    expect((q.isQuestion, q.task), (true, 't2'));
    expect(q.options, ['A', 'B']);
  });

  test('task.changed, mail kind and the SessionInfo summary', () {
    final e = AgentdEvent.parse({
      'seq': 9,
      'epoch': 'ep1',
      'kind': 'task.changed',
      'session': 'claude@webapp',
      'data': {
        'revision': 5,
        'counts': {'pending': 1, 'in_progress': 1, 'blocked': 1, 'done': 2, 'cancelled': 0},
        'current': 'Persist tasks',
        'changed': [
          {'id': 't3', 'title': 'Deploy', 'status': 'blocked', 'from': 'in_progress'},
          {'id': 't6', 'title': 'New', 'status': 'pending'},
        ],
      },
    });
    expect(e, isA<TaskChangedEvent>());
    e as TaskChangedEvent;
    expect((e.session, e.revision, e.current), ('claude@webapp', 5, 'Persist tasks'));
    expect((e.counts.pending, e.counts.inProgress, e.counts.blocked, e.counts.done), (1, 1, 1, 2));
    expect(e.changed.map((c) => '${c.id}:${c.from}>${c.status}'), ['t3:in_progress>blocked', 't6:null>pending']);

    final m = AgentdEvent.parse({
      'seq': 10,
      'kind': 'mail.queued',
      'data': {'id': 21, 'from': 'claude@webapp', 'to': 'human:u', 'kind': 'question'},
    });
    expect((m as MailEvent).mailKind, 'question');
    expect(m.session, isNull);

    final info = AgentdSessionInfo.fromJson({
      ...sessionInfoJson(),
      'tasks': {
        'revision': 5,
        'counts': {'pending': 1, 'done': 2},
        'current': 'Persist tasks',
      },
    });
    expect((info.tasks!.revision, info.tasks!.counts.done, info.tasks!.current), (5, 2, 'Persist tasks'));
    expect(AgentdSessionInfo.fromJson(sessionInfoJson()).tasks, isNull);
  });
}
