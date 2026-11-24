import 'dart:async';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/data/data.dart';
import 'package:flutter_test/flutter_test.dart';

import '../agentd/fake_daemon.dart';
import 'fakes.dart';

void main() {
  late FakeDaemon d;
  late StubHosts hosts;
  late AgentdClients clients;
  late LiveBoardRepository repo;
  late Map<String, Object?> board;
  FakeConn? bus;
  var seq = 100;
  final subs = <StreamSubscription<Object?>>[];

  void event(String kind, {String? session, Object? data}) =>
      bus!.line({'seq': ++seq, 'epoch': 'ep1', 'time': '2026-11-22T10:00:00Z', 'kind': kind, 'session': ?session, 'data': ?data});

  int boardCalls() => d.requests.where((r) => r['op'] == 'board').length;

  setUp(() {
    d = FakeDaemon();
    bus = null;
    board = boardJson();
    hosts = StubHosts([onlineHost('h', testCaps())], {'h': DataShell(daemon: d)});
    clients = AgentdClients(hosts);
    repo = LiveBoardRepository(
      hosts: hosts,
      clients: clients,
      refreshDebounce: const Duration(milliseconds: 10),
      retry: const Duration(milliseconds: 40),
    );
    // Like the daemon: an unchanged digest answers not_modified.
    d.on('board', (c) {
      if (c.args['since_digest'] == board['digest']) return c.ok({'digest': board['digest'], 'not_modified': true});
      c.ok(board);
    });
    d.on('subscribe', (c) {
      bus = c;
      c.ok({'epoch': 'ep1', 'seq': 5, 'sessions': <Object?>[]});
    });
  });

  tearDown(() async {
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    await repo.dispose();
    await clients.dispose();
  });

  List<HostBoard> watch([String host = 'h']) {
    final out = <HostBoard>[];
    subs.add(repo.watch(host).listen(out.add));
    return out;
  }

  test('emits the board, then subscribes to the kinds that change it', () async {
    final out = watch();
    await eventually(() => out.isNotEmpty && bus != null);
    final b = out.single;
    expect((b.available, b.unreadHuman, b.sessions.length), (true, 2, 2));
    expect(b.sessions.first.questions.single.id, 21);
    expect(d.lastArgs('subscribe')['kinds'], ['session', 'status', 'attention', 'mail', 'task']);
  });

  test('events refresh it, debounced and conditional on the digest', () async {
    final out = watch();
    await eventually(() => out.isNotEmpty && bus != null);

    // A burst of events is one request; an unchanged board emits nothing.
    event('status.changed', session: 'claude@webapp', data: {'status': 'working'});
    event('attention.changed', session: 'claude@webapp', data: {'attention': true});
    event('mail.queued', data: {'id': 22, 'from': 'codex@api', 'to': 'human:u', 'kind': 'question'});
    await eventually(() => boardCalls() == 2);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(boardCalls(), 2);
    expect(d.lastArgs('board'), {'since_digest': 'b1'});
    expect(out.length, 1);

    // The agent closes the question: new digest, new board.
    board = boardJson(digest: 'b2', question: false);
    event('task.changed', session: 'claude@webapp', data: {'revision': 2, 'counts': <String, Object?>{}, 'changed': <Object?>[]});
    await eventually(() => out.length == 2);
    expect(out.last.sessions.first.questions, isEmpty);

    // Screen repaints do not concern the board (and are not subscribed).
    event('heartbeat');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(boardCalls(), 3);
  });

  test('answer replies to the question and refreshes', () async {
    final out = watch();
    await eventually(() => out.isNotEmpty && bus != null);
    d.on('reply', (c) {
      board = boardJson(digest: 'b2', question: false);
      c.ok(messageJson(id: 30));
    });
    await repo.answer('h', 21, 'Same change');
    expect(d.lastArgs('reply'), {'id': 21, 'body': 'Same change'});
    await eventually(() => out.length == 2);
    expect(out.last.sessions.first.questions, isEmpty);

    await repo.answer('h', 21, 'Same change', notify: false);
    expect(d.lastArgs('reply'), {'id': 21, 'body': 'Same change', 'notify': false});
  });

  group('backlog notes', () {
    late Map<String, Object?> notes;
    int notesCalls() => d.requests.where((r) => r['op'] == 'notes').length;
    List<Object?> kinds() => d.lastArgs('subscribe')['kinds'] as List<Object?>;

    setUp(() {
      notes = notesJson(digest: 'dn1');
      d.on('notes', (c) {
        if (c.args['since_digest'] == notes['digest']) return c.ok({'digest': notes['digest'], 'not_modified': true});
        c.ok(notes);
      });
    });

    test('travel with the board; the subscription adds the note kind', () async {
      final out = watch();
      await eventually(() => out.isNotEmpty && bus != null);
      final b = out.single;
      expect((b.available, b.backlog, b.sessions.length), (true, true, 2));
      expect(b.notes.map((n) => '${n.id}:${n.state.name}'), ['3:open', '2:assigned', '1:done']);
      expect(kinds(), ['session', 'status', 'attention', 'mail', 'task', 'note']);
    });

    test('note.changed refreshes the notes alone; unchanged digests emit nothing', () async {
      final out = watch();
      await eventually(() => out.isNotEmpty && bus != null);
      event('note.changed', data: {'id': 3, 'state': 'open'});
      await eventually(() => notesCalls() == 2);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(d.lastArgs('notes'), {'since_digest': 'dn1'});
      expect(out.length, 1);

      notes = {
        'notes': [noteJson(3, 'Try the QR', state: 'assigned', assignedTo: 'codex@api')],
        'digest': 'dn2',
      };
      event('note.changed', data: {'id': 3, 'state': 'assigned'});
      await eventually(() => out.length == 2);
      expect(out.last.notes.single.assignedTo, 'codex@api');
      expect(out.last.sessions.length, 2, reason: 'the board itself was not modified and is kept');
    });

    test('an agentd older than the backlog: no section, the board still works, asked once', () async {
      d.on('notes', (c) => c.fail('unknown op "notes"', code: 'invalid'));
      final out = watch();
      await eventually(() => out.isNotEmpty && bus != null);
      expect((out.single.available, out.single.backlog, out.single.notes.length), (true, false, 0));
      expect(kinds(), ['session', 'status', 'attention', 'mail', 'task'], reason: 'an older daemon refuses a kind it does not know');
      board = boardJson(digest: 'b2', question: false);
      event('task.changed', session: 'claude@webapp', data: {'revision': 2, 'counts': <String, Object?>{}, 'changed': <Object?>[]});
      await eventually(() => out.length == 2);
      expect(notesCalls(), 1);
      await expectLater(repo.addNote('h', title: 'x'), throwsA(isA<BacklogException>().having((e) => e.failure, 'failure', BacklogFailure.unavailable)));
    });

    test('a store that is not ready is asked again, then the note kind is subscribed', () async {
      d.on('notes', (c) => c.fail('backlog: store unavailable', code: 'not_ready'));
      final out = watch();
      await eventually(() => out.isNotEmpty && bus != null);
      expect(out.single.backlog, isFalse);
      d.on('notes', (c) => c.ok(notes));
      event('status.changed', session: 'claude@webapp', data: {'status': 'idle'});
      await eventually(() => out.length == 2);
      expect((out.last.backlog, out.last.notes.length), (true, 3));
      await eventually(() => d.requests.where((r) => r['op'] == 'subscribe').length == 2);
      expect(kinds(), contains('note'));
    });

    test('a relay device that may not use the backlog never asks for it', () async {
      for (final relay in [
        const RelayHostInfo(relayUrl: 'https://r.example', route: 'r', hostKey: 'k', deviceId: 'd', scope: RelayScope.view, kind: 'owner'),
        const RelayHostInfo(relayUrl: 'https://r.example', route: 'r', hostKey: 'k', deviceId: 'd', scope: RelayScope.admin, kind: 'guest'),
        const RelayHostInfo(relayUrl: 'https://r.example', route: 'r', hostKey: 'k', deviceId: 'd', scope: RelayScope.admin, kind: 'owner', sessions: ['claude@*']),
      ]) {
        expect(HostConfig(id: 'x', name: 'x', host: 'r', user: '', transport: HostTransport.relay, relay: relay).canBacklog, isFalse);
      }
      const owner = RelayHostInfo(relayUrl: 'https://r.example', route: 'r', hostKey: 'k', deviceId: 'd', scope: RelayScope.operate, kind: 'owner');
      expect(const HostConfig(id: 'x', name: 'x', host: 'r', user: '', transport: HostTransport.relay, relay: owner).canBacklog, isTrue);
      expect(const HostConfig(id: 'x', name: 'x', host: 'h', user: 'u').canBacklog, isTrue);
    });

    test('changes send the op, refresh the board and map refusals', () async {
      final out = watch();
      await eventually(() => out.isNotEmpty && bus != null);
      d.on('note_add', (c) {
        notes = {
          'notes': [noteJson(4, 'New idea', body: 'why'), ...(notes['notes'] as List)],
          'digest': 'dn2',
        };
        c.ok(noteJson(4, 'New idea', body: 'why'));
      });
      final n = await repo.addNote('h', title: 'New idea', body: 'why');
      expect((n.id, n.title, n.body, n.state), (4, 'New idea', 'why', NoteState.open));
      expect(d.lastArgs('note_add'), {'title': 'New idea', 'body': 'why'});
      await eventually(() => out.length == 2);
      expect(out.last.notes.first.id, 4);

      d.answer('note_update', noteJson(4, 'Newer idea'));
      expect((await repo.updateNote('h', 4, title: 'Newer idea')).title, 'Newer idea');
      expect(d.lastArgs('note_update'), {'id': 4, 'title': 'Newer idea'});
      await repo.updateNote('h', 2, reopen: true);
      expect(d.lastArgs('note_update'), {'id': 2, 'state': 'open'});

      d.answer('note_assign', {
        'note': noteJson(4, 'Newer idea', state: 'assigned', assignedTo: 'codex@api'),
        'task': {...taskJson('n4', 'Newer idea', status: 'in_progress'), 'origin': 'backlog'},
        'warning': 'mailbox: store closed',
      });
      expect(await repo.assignNote('h', 4, session: 'codex@api', inProgress: true), 'mailbox: store closed');
      expect(d.lastArgs('note_assign'), {'id': 4, 'session': 'codex@api', 'status': 'in_progress'});

      d.answer('note_rm', noteJson(4, 'Newer idea'));
      await repo.removeNote('h', 4);
      expect(d.lastArgs('note_rm'), {'id': 4});

      for (final (code, failure) in [('exited', BacklogFailure.sessionNotRunning), ('invalid', BacklogFailure.invalid), ('not_found', BacklogFailure.notFound)]) {
        d.on('note_assign', (c) => c.fail('refused', code: code));
        await expectLater(repo.assignNote('h', 1, session: 's'), throwsA(isA<BacklogException>().having((e) => e.failure, 'failure', failure)));
      }
      await expectLater(repo.addNote('nope', title: 'x'), throwsA(isA<BacklogException>().having((e) => e.failure, 'failure', BacklogFailure.unavailable)));
    });
  });

  test('a daemon without the board is unavailable, and asked again later', () async {
    d.handlers.remove('board');
    final out = watch();
    await eventually(() => out.isNotEmpty);
    expect(out.single.available, isFalse);
    expect(out.single.sessions, isEmpty);
    expect(d.requests.where((r) => r['op'] == 'subscribe'), isEmpty, reason: 'no task kinds to subscribe to');

    // The daemon was upgraded.
    d.answer('board', board);
    await eventually(() => out.length == 2);
    expect(out.last.available, isTrue);
  });

  test('a forbidden board (relay guest gate) is unavailable', () async {
    d.on('board', (c) => c.fail('forbidden', code: 'forbidden'));
    final out = watch();
    await eventually(() => out.isNotEmpty);
    expect(out.single.available, isFalse);
  });

  test('hosts without agentd or offline have no board; coming online loads it', () async {
    hosts.set([onlineHost('h', testCaps(agentd: false))]);
    final out = watch();
    await eventually(() => out.isNotEmpty);
    expect(out.single.available, isFalse);
    expect(boardCalls(), 0);

    hosts.set([onlineHost('h', testCaps())]);
    await eventually(() => out.length == 2);
    expect(out.last.sessions.length, 2);

    hosts.set([HostStatus(const HostConfig(id: 'h', name: 'h', host: 'h.local', user: 'u'))]);
    await eventually(() => out.length == 3);
    expect(out.last.available, isFalse);
  });

  test('a relay host reads its board through the tunnel', () async {
    final relay = HostStatus(
      const HostConfig(
        id: 'r',
        name: 'r',
        host: 'relay.example',
        user: '',
        transport: HostTransport.relay,
        relay: RelayHostInfo(relayUrl: 'wss://relay.example', route: 'x', hostKey: 'k', deviceId: 'd', scope: RelayScope.view, kind: 'guest'),
      ),
      state: HostState.online,
      capabilities: testCaps(),
    );
    hosts.set([relay]);
    var dials = 0;
    hosts.relayDial = (_) {
      dials++;
      return d.dial();
    };
    // A guest device gets no questions (the daemon filters them).
    board = boardJson(question: false);
    final out = watch('r');
    await eventually(() => out.isNotEmpty);
    expect(dials, greaterThan(0));
    expect(out.single.sessions.first.questions, isEmpty);
    expect(out.single.sessions.first.tasks.length, 5);
  });

  test('stops asking when nobody listens', () async {
    final out = watch();
    await eventually(() => out.isNotEmpty && bus != null);
    await subs.removeLast().cancel();
    await eventually(() => bus!.end.isClosed);
    final n = boardCalls();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(boardCalls(), n);
  });
}
