// Backlog notes wire: ops notes / note_add / note_update / note_rm /
// note_assign, the note.changed event and Task.origin.

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

  test('notes: every field, the states filter and the digest', () async {
    d.on('notes', (conn) {
      if (conn.args['since_digest'] == 'd0123456789abcdef') return conn.ok({'digest': 'd0123456789abcdef', 'not_modified': true});
      conn.ok(notesJson());
    });
    final r = await c.notes();
    expect(d.lastArgs('notes'), isEmpty);
    expect((r.digest, r.notModified, r.notes.length), ('d0123456789abcdef', false, 3));
    final open = r.notes.first;
    expect((open.id, open.title, open.body, open.state, open.assignedTo, open.taskId), (3, 'Try the QR', 'On a real phone', 'open', null, null));
    expect(open.createdAt, DateTime.utc(2026, 11, 24, 10));
    final assigned = r.notes[1];
    expect((assigned.state, assigned.assignedTo, assigned.taskId, assigned.body), ('assigned', 'claude@webapp', 'n2', ''));
    expect(assigned.assignedAt, DateTime.utc(2026, 11, 24, 11));
    expect((r.notes[2].state, r.notes[2].doneAt), ('done', DateTime.utc(2026, 11, 23, 9)));

    final again = await c.notes(states: ['open', 'assigned'], sinceDigest: r.digest);
    expect(d.lastArgs('notes'), {
      'states': ['open', 'assigned'],
      'since_digest': 'd0123456789abcdef',
    });
    expect(again.notModified, isTrue);
    expect(again.notes, isEmpty);
  });

  test('note_add, note_update and note_rm send exactly the daemon args', () async {
    d.answer('note_add', noteJson(7, 'Idea'));
    d.answer('note_update', noteJson(7, 'Idea 2'));
    d.answer('note_rm', noteJson(7, 'Idea 2'));

    expect((await c.noteAdd('Idea')).id, 7);
    expect(d.lastArgs('note_add'), {'title': 'Idea'});
    await c.noteAdd('Idea', body: 'line 1\nline 2');
    expect(d.lastArgs('note_add'), {'title': 'Idea', 'body': 'line 1\nline 2'});

    expect((await c.noteUpdate(7, title: 'Idea 2')).title, 'Idea 2');
    expect(d.lastArgs('note_update'), {'id': 7, 'title': 'Idea 2'});
    // An empty body clears it; null leaves it.
    await c.noteUpdate(7, body: '');
    expect(d.lastArgs('note_update'), {'id': 7, 'body': ''});
    await c.noteUpdate(7, reopen: true);
    expect(d.lastArgs('note_update'), {'id': 7, 'state': 'open'});

    await c.noteRm(7);
    expect(d.lastArgs('note_rm'), {'id': 7});
  });

  test('note_assign: status and notify only when not the default; the task has origin backlog', () async {
    d.answer('note_assign', {
      'note': noteJson(2, 'Docs', state: 'assigned', assignedTo: 'claude@webapp'),
      'task': {...taskJson('n2', 'Docs'), 'origin': 'backlog'},
      'message_id': 41,
    });
    final r = await c.noteAssign(2, 'claude@webapp');
    expect(d.lastArgs('note_assign'), {'id': 2, 'session': 'claude@webapp'});
    expect((r.note.state, r.task.id, r.task.origin, r.messageId, r.warning), ('assigned', 'n2', 'backlog', 41, null));
    expect(toAgentTask(r.task).fromBacklog, isTrue);
    expect(toAgentTask(AgentdTask.fromJson(taskJson('t1', 'Own'))).fromBacklog, isFalse);

    d.answer('note_assign', {
      'note': noteJson(2, 'Docs', state: 'assigned', assignedTo: 'claude@webapp'),
      'task': taskJson('n2', 'Docs', status: 'in_progress'),
      'warning': 'mailbox: store closed',
    });
    final w = await c.noteAssign(2, 'claude@webapp', inProgress: true, notify: false);
    expect(d.lastArgs('note_assign'), {'id': 2, 'session': 'claude@webapp', 'status': 'in_progress', 'notify': false});
    expect((w.messageId, w.warning), (null, 'mailbox: store closed'));
  });

  test('refusals keep the daemon code and map to the contract', () async {
    for (final (code, failure) in [
      ('invalid', BacklogFailure.invalid),
      ('not_found', BacklogFailure.notFound),
      ('exited', BacklogFailure.sessionNotRunning),
      ('starting', BacklogFailure.sessionNotRunning),
      ('forbidden', BacklogFailure.forbidden),
      ('not_ready', BacklogFailure.unavailable),
    ]) {
      d.on('note_assign', (conn) => conn.fail('refused', code: code));
      try {
        await c.noteAssign(1, 's');
        fail('no error for $code');
      } on AgentdError catch (e) {
        expect(e.code, code);
        expect(toBacklogException(e).failure, failure);
      }
    }
  });

  test('note.changed is host wide: id, state, removed', () {
    final e = AgentdEvent.parse({
      'seq': 9,
      'epoch': 'ep1',
      'time': '2026-11-24T10:00:00Z',
      'kind': 'note.changed',
      'data': {'id': 4, 'state': 'assigned'},
    });
    expect(e, isA<NoteChangedEvent>());
    e as NoteChangedEvent;
    expect((e.id, e.state, e.removed, e.session, e.seq), (4, 'assigned', false, null, 9));
    final r = AgentdEvent.parse({
      'seq': 10,
      'epoch': 'ep1',
      'kind': 'note.changed',
      'data': {'id': 4, 'removed': true},
    });
    expect(((r as NoteChangedEvent).state, r.removed), (null, true));
  });

  test('mapping: states, and an unknown one stays open', () {
    final notes = [for (final n in AgentdNotesResult.fromJson(notesJson()).notes) toBacklogNote(n)];
    expect(notes.map((n) => n.state), [NoteState.open, NoteState.assigned, NoteState.done]);
    expect((notes[1].assignedTo, notes[1].taskId), ('claude@webapp', 'n2'));
    expect(toBacklogNote(AgentdNote.fromJson({...noteJson(1, 'x'), 'state': 'archived'})).state, NoteState.open);
  });
}
