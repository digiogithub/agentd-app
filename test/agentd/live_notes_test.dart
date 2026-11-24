// Live check of the backlog and relay-devices wire against a real agentd
// (>= the backlog). Skipped unless AGENTD_TEST_SOCKET names the unix socket
// of a THROWAWAY daemon (its own AGENTD_SOCKET and AGENTD_STATE_DIR, never
// the user's daemon): the test writes notes into it. AGENTD_TEST_SESSION, a
// running session of that daemon (a plain shell is enough), also checks
// note_assign.
//
//   d=$(mktemp -d); export AGENTD_SOCKET=$d/s AGENTD_STATE_DIR=$d/state
//   agentd daemon &  agentd run $d --name sh@live -- sh
//   AGENTD_TEST_SOCKET=$d/s AGENTD_TEST_SESSION=sh@live flutter test test/agentd/live_notes_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:agentd_app/src/agentd/agentd.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

class _SocketChannel implements ByteChannel {
  _SocketChannel(this._s);
  final Socket _s;

  @override
  Stream<Uint8List> get stream => _s;

  @override
  void add(List<int> data) => _s.add(data);

  @override
  Future<void> close() async {
    await _s.flush().catchError((Object _) {});
    _s.destroy();
  }

  @override
  Future<void> get done => _s.done.catchError((Object _) {});
}

void main() {
  final path = Platform.environment['AGENTD_TEST_SOCKET'];
  final session = Platform.environment['AGENTD_TEST_SESSION'];
  final skip = path == null || path.isEmpty ? 'set AGENTD_TEST_SOCKET to the socket of a throwaway agentd' : null;

  AgentdClient client() => AgentdClient(() async => _SocketChannel(await Socket.connect(InternetAddress(path!, type: InternetAddressType.unix), 0)));

  test('backlog ops and note.changed against a real daemon', skip: skip, () async {
    final c = client();
    final sub = c.subscribe(kinds: const ['note', 'task']);
    final events = <AgentdEvent>[];
    final listening = sub.events.listen(events.add);
    addTearDown(listening.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final before = await c.notes();
    final added = await c.noteAdd('Live note ${DateTime.now().microsecondsSinceEpoch}', body: 'line 1\nline 2');
    expect((added.state, added.body), ('open', 'line 1\nline 2'));
    final listed = await c.notes();
    expect(listed.notes.first.id, added.id, reason: 'open notes, newest first');
    expect(listed.digest, isNot(before.digest));
    expect((await c.notes(sinceDigest: listed.digest)).notModified, isTrue);
    expect((await c.notes(states: ['done'])).notes.where((n) => n.id == added.id), isEmpty);

    final edited = await c.noteUpdate(added.id, title: 'Live note edited', body: '');
    expect((edited.title, edited.body), ('Live note edited', ''));
    await expectLater(c.noteAdd('   '), throwsA(isA<AgentdError>().having((e) => e.code, 'code', 'invalid')));
    await expectLater(c.noteUpdate(1 << 40, title: 'x'), throwsA(isA<AgentdError>().having((e) => e.code, 'code', 'not_found')));
    await expectLater(c.noteAssign(added.id, 'no-such@session'), throwsA(isA<AgentdError>().having((e) => toBacklogException(e).failure, 'failure', BacklogFailure.notFound)));

    if (session != null && session.isNotEmpty) {
      final r = await c.noteAssign(added.id, session, inProgress: true, notify: false);
      expect((r.note.state, r.note.assignedTo, r.note.taskId), ('assigned', session, 'n${added.id}'));
      expect((r.task.id, r.task.status, r.task.origin, r.messageId), ('n${added.id}', 'in_progress', 'backlog', null));
      final board = toHostBoard(await c.board(), hostId: 'h');
      final task = board.sessions.firstWhere((s) => s.name == session).tasks.firstWhere((t) => t.id == 'n${added.id}');
      expect((task.fromBacklog, task.status), (true, TaskStatus.inProgress));
      final reopened = await c.noteUpdate(added.id, reopen: true);
      expect((reopened.state, reopened.assignedTo), ('open', null));
    }

    final removed = await c.noteRm(added.id);
    expect(removed.id, added.id);
    expect((await c.notes()).notes.where((n) => n.id == added.id), isEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final mine = [for (final e in events.whereType<NoteChangedEvent>()) if (e.id == added.id) e];
    expect(mine.first.state, 'open');
    expect(mine.last.removed, isTrue);
    expect(mine.every((e) => e.session == null), isTrue);
  });
}
