import 'dart:async';

import 'package:agentd_app/src/agentd/client.dart';
import 'package:agentd_app/src/agentd/errors.dart';
import 'package:agentd_app/src/agentd/events.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_daemon.dart';

Map<String, Object?> ev(String kind, {int seq = 0, String epoch = 'ep1', String? session, Object? data}) => {
  'seq': seq,
  'epoch': epoch,
  'time': '2026-11-15T10:00:00Z',
  'kind': kind,
  'session': ?session,
  'data': ?data,
};

/// Collects events until [until] matches, then returns them.
Future<List<AgentdEvent>> collect(Stream<AgentdEvent> s, bool Function(AgentdEvent) until, List<StreamSubscription<AgentdEvent>> keep) {
  final out = <AgentdEvent>[];
  final done = Completer<List<AgentdEvent>>();
  keep.add(
    s.listen(
      (e) {
        out.add(e);
        if (!done.isCompleted && until(e)) done.complete(List.of(out));
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(out);
      },
    ),
  );
  return done.future.timeout(const Duration(seconds: 5));
}

void main() {
  late FakeDaemon d;
  late AgentdClient c;

  setUp(() {
    d = FakeDaemon(serverChunk: 7);
    c = AgentdClient(d.dial);
  });

  test('typed events, then reconnect with since_seq + epoch and dedupe', () async {
    var n = 0;
    d.on('subscribe', (k) async {
      n++;
      if (n == 1) {
        k.ok({
          'epoch': 'ep1',
          'seq': 10,
          'sessions': [sessionInfoJson()],
        });
        k.line(ev('hello', data: {'epoch': 'ep1', 'seq': 10}));
        k.line(
          ev(
            'status.changed',
            seq: 11,
            session: 'claude@webapp',
            data: {'from': 'working', 'status': 'idle', 'reason': 'quiet', 'attention': true, 'revision': 8, 'turn': 4},
          ),
        );
        k.line(ev('view.changed', seq: 12, session: 'claude@webapp', data: {'revision': 8}));
        k.line(ev('mail.queued', seq: 13, session: 'claude@webapp', data: {'id': 3, 'from': 'human:u', 'to': 'claude@webapp'}));
        k.line(ev('session.exited', seq: 14, session: 'x', data: {'exit_code': 2}));
        k.line(
          ev(
            'turn.completed',
            seq: 15,
            session: 'claude@webapp',
            data: {'turn': 4, 'outcome': 'completed', 'origin': 'act', 'status': 'idle', 'ended_at': '2026-11-15T10:00:00Z'},
          ),
        );
        k.line(ev('doc.changed', seq: 16, data: {'name': 'herdr-app', 'version': 2}));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await k.close();
      } else {
        k.ok({'epoch': 'ep1', 'seq': 17, 'sessions': []});
        k.line(ev('hello', data: {'epoch': 'ep1', 'seq': 17}));
        k.line(ev('view.changed', seq: 16, session: 'claude@webapp', data: {'revision': 8})); // replay overlap
        k.line(ev('input.changed', seq: 17, session: 'claude@webapp', data: {'state': 'draft'}));
        k.line(ev('resync', data: {'reason': 'overflow'}));
        k.line(ev('heartbeat'));
      }
    });
    final sub = c.subscribe(kinds: ['status', 'view'], heartbeatMs: 1000, minBackoff: const Duration(milliseconds: 10));
    final keep = <StreamSubscription<AgentdEvent>>[];
    final got = await collect(sub.events, (e) => e is HeartbeatEvent, keep);

    expect(d.requests.first['args'], {
      'kinds': ['status', 'view'],
      'heartbeat_ms': 1000,
    });
    expect(d.requests[1]['args'], {
      'kinds': ['status', 'view'],
      'since_seq': 16,
      'epoch': 'ep1',
      'heartbeat_ms': 1000,
    });

    final first = got[0] as SubscribedEvent;
    expect(first.reconnect, isFalse);
    expect(first.resumed, isFalse);
    expect(first.result.sessions.single.name, 'claude@webapp');
    expect(got[1], isA<HelloEvent>());
    final st = got[2] as StatusChangedEvent;
    expect((st.from, st.status, st.attention, st.revision, st.turn, st.session), ('working', 'idle', true, 8, 4, 'claude@webapp'));
    expect((got[3] as ViewChangedEvent).revision, 8);
    final mail = got[4] as MailEvent;
    expect((mail.kind, mail.id, mail.to), ('mail.queued', 3, 'claude@webapp'));
    expect((got[5] as SessionExitedEvent).exitCode, 2);
    expect((got[6] as TurnCompletedEvent).turn.origin, 'act');
    expect(got[7], isA<OtherEvent>());
    expect(got[8], isA<DisconnectedEvent>());

    final second = got[9] as SubscribedEvent;
    expect(second.reconnect, isTrue);
    expect(second.resumed, isTrue);
    expect(second.epochChanged, isFalse);
    expect(got[10], isA<HelloEvent>());
    // seq 16 replayed again is dropped.
    expect((got[11] as InputChangedEvent).state, 'draft');
    expect((got[12] as ResyncEvent).reason, 'overflow');
    expect(sub.lastSeq, 17);
    expect(sub.epoch, 'ep1');

    await sub.close();
    for (final k in keep) {
      await k.cancel();
    }
  });

  test('daemon restart: epoch change resets seq and is flagged', () async {
    var n = 0;
    d.on('subscribe', (k) async {
      n++;
      if (n == 1) {
        k.ok({'epoch': 'ep1', 'seq': 50, 'sessions': []});
        k.line(ev('bye'));
      } else {
        k.ok({'epoch': 'ep2', 'seq': 2, 'sessions': []});
        k.line(ev('hello', epoch: 'ep2', data: {'epoch': 'ep2', 'seq': 2}));
        k.line(ev('resync', epoch: 'ep2', data: {'reason': 'epoch_mismatch'}));
      }
    });
    final sub = c.subscribe(minBackoff: const Duration(milliseconds: 5));
    final keep = <StreamSubscription<AgentdEvent>>[];
    final got = await collect(sub.events, (e) => e is ResyncEvent, keep);
    expect(got.whereType<ByeEvent>(), hasLength(1));
    expect(d.lastArgs('subscribe'), {'since_seq': 50, 'epoch': 'ep1'});
    final again = got.whereType<SubscribedEvent>().last;
    expect(again.epochChanged, isTrue);
    expect(again.resumed, isFalse);
    expect(sub.epoch, 'ep2');
    expect(sub.lastSeq, 2);
    await sub.close();
    for (final k in keep) {
      await k.cancel();
    }
  });

  test('resume from a caller-provided seq and epoch', () async {
    d.on('subscribe', (k) => k.ok({'epoch': 'ep9', 'seq': 120, 'sessions': []}));
    final sub = c.subscribe(sinceSeq: 100, epoch: 'ep9');
    final keep = <StreamSubscription<AgentdEvent>>[];
    final got = await collect(sub.events, (e) => e is SubscribedEvent, keep);
    expect(d.lastArgs('subscribe'), {'since_seq': 100, 'epoch': 'ep9'});
    expect((got.single as SubscribedEvent).resumed, isTrue);
    expect(sub.lastSeq, 100);
    await sub.close();
    for (final k in keep) {
      await k.cancel();
    }
  });

  test('invalid args are fatal: error then done', () async {
    d.on('subscribe', (k) => k.fail('since_seq requires epoch', code: 'invalid'));
    final sub = c.subscribe(minBackoff: const Duration(milliseconds: 5));
    await expectLater(sub.events, emitsInOrder([emitsError(isA<AgentdError>()), emitsDone]));
    expect(d.dials, 1);
  });

  test('without reconnect the stream ends with the connection', () async {
    d.on('subscribe', (k) async {
      k.ok({'epoch': 'e', 'seq': 0, 'sessions': []});
      await k.close();
    });
    final sub = c.subscribe(reconnect: false);
    await expectLater(sub.events, emitsInOrder([isA<SubscribedEvent>(), emitsDone]));
  });

  test('silence past the idle timeout reconnects', () async {
    d.on('subscribe', (k) => k.ok({'epoch': 'e', 'seq': 0, 'sessions': []}));
    final sub = c.subscribe(idleTimeout: const Duration(milliseconds: 50), minBackoff: const Duration(milliseconds: 5));
    final keep = <StreamSubscription<AgentdEvent>>[];
    final got = await collect(sub.events, (e) => e is SubscribedEvent && e.reconnect, keep);
    final disc = got.whereType<DisconnectedEvent>().first;
    expect(disc.error, isA<AgentdTransportError>());
    expect(d.dials, greaterThanOrEqualTo(2));
    await sub.close();
    for (final k in keep) {
      await k.cancel();
    }
    expect(d.clientEnds.every((e) => e.isClosed), isTrue);
  });

  test('dial failures back off and retry', () async {
    d.dialError = StateError('ssh down');
    final sub = c.subscribe(minBackoff: const Duration(milliseconds: 5), maxBackoff: const Duration(milliseconds: 20));
    final keep = <StreamSubscription<AgentdEvent>>[];
    final got = await collect(sub.events, (e) => e is DisconnectedEvent && d.dials >= 3, keep);
    final retries = got.whereType<DisconnectedEvent>().map((e) => e.retryIn!).toList();
    expect(retries.first, const Duration(milliseconds: 5));
    expect(retries.every((r) => r <= const Duration(milliseconds: 20)), isTrue);
    d.dialError = null;
    d.on('subscribe', (k) => k.ok({'epoch': 'e', 'seq': 0, 'sessions': []}));
    await sub.close();
    for (final k in keep) {
      await k.cancel();
    }
  });
}
