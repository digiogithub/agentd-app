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
