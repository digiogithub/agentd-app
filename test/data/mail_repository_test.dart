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
  late AgentdMailRepository repo;
  final subs = <StreamSubscription<Object?>>[];

  setUp(() {
    d = FakeDaemon();
    hosts = StubHosts([onlineHost('h', testCaps())], {'h': DataShell(daemon: d)});
    clients = AgentdClients(hosts);
    repo = AgentdMailRepository(clients: clients, poll: const Duration(milliseconds: 30));
    d.on('inbox', (c) {
      final as = c.args['as'];
      if (as == null) {
        return c.ok({
          'messages': [messageJson(id: 3, state: 'delivered')],
          'digest': 'dmine',
          if (c.args['since_digest'] == 'dmine') 'not_modified': true,
        });
      }
      c.ok({
        'messages': [
          {...messageJson(id: 1), 'sender': 'claude@webapp', 'recipient': as, 'created_at': '2026-11-15T08:00:00Z'},
        ],
        'digest': 'd$as',
      });
    });
    d.answer('ls', {
      'sessions': [sessionInfoJson(name: 'codex@api')],
    });
    d.on('queue', (c) {
      if (c.args['name'] == null) {
        return c.ok({
          'queues': [
            {'name': 'review', 'unclaimed': 1},
          ],
        });
      }
      c.ok({
        'name': 'review',
        'items': [messageJson(id: 7, state: 'unclaimed', queue: 'review')],
        'digest': 'dq',
      });
    });
  });

  tearDown(() async {
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    await clients.dispose();
  });

  test('inbox merges my mailbox, peeks at session mailboxes and queue items', () async {
    List<MailMessage> mail = const [];
    subs.add(repo.inbox('h').listen((m) => mail = m));
    await eventually(() => mail.length == 3);
    expect(mail.map((m) => m.id), [1, 3, 7]); // by creation time
    expect(mail.first.to, 'codex@api');
    expect(mail.last.state, MailState.unclaimed);
    expect(mail.last.queue, 'review');
    final peek = d.requests.firstWhere((r) => r['op'] == 'inbox' && (r['args'] as Map)['as'] == 'codex@api');
    expect((peek['args'] as Map)['all'], isTrue);
    expect(d.requests.where((r) => r['op'] == 'queue' && (r['args'] as Map)['name'] == 'review').first['args'], containsPair('bodies', true));
    // Later polls are conditional.
    await eventually(() => d.requests.any((r) => r['op'] == 'inbox' && (r['args'] as Map)['since_digest'] == 'dmine'));
  });

  test('queues and send', () async {
    List<WorkQueue> qs = const [];
    subs.add(repo.queues('h').listen((q) => qs = q));
    await eventually(() => qs.isNotEmpty);
    expect((qs.single.name, qs.single.unclaimed), ('review', 1));
    expect(d.requests.where((r) => r['op'] == 'inbox'), isEmpty, reason: 'queues alone do not read mailboxes');

    d.answer('send', messageJson(id: 9));
    await repo.send('h', to: 'queue:review', body: 'revisa el PR', subject: 'PR 12');
    expect(d.lastArgs('send'), {'to': 'queue:review', 'subject': 'PR 12', 'body': 'revisa el PR'});
  });

  test('a host without agentd has an empty mailbox', () async {
    hosts.set([onlineHost('h', testCaps(agentd: false))]);
    final r = AgentdMailRepository(clients: AgentdClients(hosts));
    expect(await r.inbox('h').first, isEmpty);
  });
}
