import 'dart:async';
import 'dart:convert';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/data/data.dart';
import 'package:agentd_app/src/mux/mux.dart';
import 'package:flutter_test/flutter_test.dart';

import '../agentd/fake_daemon.dart';
import 'fakes.dart';

// Bus seqs must be above the snapshot's (5): older ones are deduplicated.
var _seq = 100;
Map<String, Object?> ev(String kind, {int? seq, String? session, Object? data}) => {
  'seq': seq ?? ++_seq,
  'epoch': 'ep1',
  'time': '2026-11-15T10:00:00Z',
  'kind': kind,
  'session': ?session,
  'data': ?data,
};

class _Mux implements MuxAdapter {
  _Mux(this.source, this.sessions);
  @override
  final SessionSource source;
  List<AgentSession> sessions;
  int lists = 0;
  final List<String> attached = [];
  final List<({String session, String cwd, List<String> command})> launched = [];

  @override
  Future<List<AgentSession>> list({bool withPanes = true}) async {
    lists++;
    return sessions;
  }

  @override
  Future<PtySession> attach(String name, {int cols = 80, int rows = 24}) async {
    attached.add(name);
    return TestPty();
  }

  @override
  Future<AgentSession> launch({required String session, required String cwd, required List<String> command, String? harness}) async {
    launched.add((session: session, cwd: cwd, command: command));
    return AgentSession(hostId: 'h', source: source, name: session, harness: harness);
  }

  @override
  Future<void> kill(String name) async {}
}

void main() {
  late FakeDaemon d;
  late DataShell shell;
  late StubHosts hosts;
  late AgentdClients clients;
  late LiveSessionsRepository repo;
  late FakeConn? bus;
  late _Mux zellij;
  late Map<String, Object?> view;
  final subs = <StreamSubscription<Object?>>[];

  LiveSessionsRepository make({HostCapabilities? caps}) {
    hosts = StubHosts([onlineHost('h', caps ?? testCaps())], {'h': shell});
    clients = AgentdClients(hosts);
    return LiveSessionsRepository(
      hosts: hosts,
      clients: clients,
      mux: (sh, h) => [if (h.capabilities?.has('zellij') ?? false) zellij],
      muxPoll: const Duration(milliseconds: 40),
      refreshDebounce: const Duration(milliseconds: 5),
      promptRetry: const Duration(milliseconds: 5),
    );
  }

  setUp(() {
    d = FakeDaemon();
    shell = DataShell(daemon: d);
    bus = null;
    view = viewJson();
    zellij = _Mux(SessionSource.zellij, [const AgentSession(hostId: 'h', source: SessionSource.zellij, name: 'main', detail: '2 panes')]);
    d.on('subscribe', (c) {
      bus = c;
      c.ok({
        'epoch': 'ep1',
        'seq': 5,
        'sessions': [sessionInfoJson(status: 'waiting', attention: true), sessionInfoJson(name: 'codex@api', status: 'working', preview: 'Running')],
      });
    });
    d.on('view', (c) {
      // Like the daemon: unchanged revision + epoch = not_modified.
      if (c.args['since_revision'] == view['revision'] && c.args['epoch'] == view['epoch']) {
        return c.ok({'not_modified': true, 'name': view['name'], 'epoch': view['epoch'], 'revision': view['revision']});
      }
      c.ok(view);
    });
    d.answer('view_ack', {'revision': 9});
    repo = make();
  });

  tearDown(() async {
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    await repo.dispose();
    await clients.dispose();
  });

  AgentSession? byName(List<AgentSession> l, String n) => l.where((s) => s.name == n).firstOrNull;

  // Polls the latest list until [cond].
  Future<List<AgentSession>> until(bool Function(List<AgentSession>) cond) async {
    List<AgentSession> last = const [];
    final sub = repo.watch().listen((l) => last = l);
    subs.add(sub);
    await eventually(() => cond(last));
    return last;
  }

  test('subscription snapshot lists sessions; waiting ones get their classified question', () async {
    final l = await until((l) => byName(l, 'claude@webapp')?.pending != null);
    final s = byName(l, 'claude@webapp')!;
    expect(s.status, AgentStatus.waiting);
    expect(s.attention, isTrue);
    expect(s.pending!.kind, PendingKind.permission);
    expect(s.pending!.question, 'Do you want to proceed?');
    expect(s.pending!.options.map((o) => (o.id, o.kind)), [('o1', OptionKind.numbered), ('o2', OptionKind.numbered)]);
    expect(s.pending!.revision, 9);
    expect(s.pending!.epoch, 'ep1');
    expect(byName(l, 'codex@api')!.status, AgentStatus.working);
    expect(byName(l, 'codex@api')!.pending, isNull);
    expect(shell.sockets.first, '/run/user/1000/agentd/agentd.sock');
    // The inbox view is short (no full transcript for a card).
    expect(d.lastArgs('view')['lines_limit'], 40);
  });

  test('bus events update the list', () async {
    await until((l) => byName(l, 'codex@api') != null);
    bus!.line(ev('status.changed', session: 'codex@api', data: {'from': 'working', 'status': 'idle', 'attention': true, 'revision': 3, 'turn': 4}));
    var l = await until((l) => byName(l, 'codex@api')?.status == AgentStatus.idle);
    expect(byName(l, 'codex@api')!.attention, isTrue);
    expect(byName(l, 'codex@api')!.turn, 4);

    bus!.line(ev('turn.completed', session: 'codex@api', data: {'turn': 4, 'outcome': 'completed', 'message': 'All green'}));
    l = await until((l) => byName(l, 'codex@api')?.preview == 'All green');

    bus!.line(ev('session.created', session: 'pando@pips', data: sessionInfoJson(name: 'pando@pips', status: null, state: 'starting')));
    l = await until((l) => byName(l, 'pando@pips') != null);
    expect(byName(l, 'pando@pips')!.status, AgentStatus.starting);

    bus!.line(ev('session.removed', session: 'pando@pips'));
    await until((l) => byName(l, 'pando@pips') == null);
  });

  test('view feed: emits, acks attention, refreshes conditionally on view.changed', () async {
    final l = await until((l) => byName(l, 'claude@webapp') != null);
    final views = <SessionView>[];
    subs.add(repo.view(byName(l, 'claude@webapp')!).listen(views.add));
    await eventually(() => views.isNotEmpty);
    final v = views.last;
    expect(v.revision, 9);
    expect(v.items.map((i) => i.role), [ChatRole.user, ChatRole.agent, ChatRole.tool, ChatRole.system]);
    expect(v.items[2].meta, '3 errors found');
    expect(v.session.pending!.kind, PendingKind.permission);
    await eventually(() => d.requests.any((r) => r['op'] == 'view_ack'));

    view = viewJson(status: 'working', revision: 10)
      ..remove('dialog')
      ..['options'] = [];
    bus!.line(ev('view.changed', session: 'claude@webapp', data: {'revision': 10}));
    await eventually(() => views.last.revision == 10);
    expect(d.lastArgs('view')['since_revision'], 9);
    expect(d.lastArgs('view')['epoch'], 'ep1');
    expect(views.last.session.pending, isNull);
    expect(views.last.session.status, AgentStatus.working);
    // The list follows the open view.
    await until((l) => byName(l, 'claude@webapp')?.status == AgentStatus.working);
  });

  test('choose sends the option with revision and epoch; a conflict refreshes the view', () async {
    final l = await until((l) => byName(l, 'claude@webapp')?.pending != null);
    final s = byName(l, 'claude@webapp')!;
    final views = <SessionView>[];
    subs.add(repo.view(s).listen(views.add));
    await eventually(() => views.isNotEmpty);

    d.answer('act', {'revision': 10, 'status': 'working', 'result': 'selected'});
    await repo.choose(s, s.pending!.options.first, revision: 9, epoch: 'ep1');
    final a = d.lastArgs('act');
    expect(a['action'], 'choose');
    expect(a['option_id'], 'o1');
    expect(a['label'], 'Yes');
    expect((a['revision'], a['epoch']), (9, 'ep1'));
    expect(a['client'], 'agentd-app');

    final fresh = view = viewJson(revision: 12);
    d.on('act', (c) => c.fail('menu changed', code: 'conflict', data: {'revision': 12, 'view': fresh}));
    await expectLater(repo.choose(s, s.pending!.options.first, revision: 9, epoch: 'ep1'), throwsA(anything));
    await eventually(() => views.last.revision == 12);
    final viewsBefore = views.length;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(views.length, viewsBefore, reason: 'the refresh after the conflict is not_modified');
  });

  test('prompt, keys and interrupt are act calls; mux sessions refuse them', () async {
    final l = await until((l) => byName(l, 'codex@api') != null && byName(l, 'main') == null);
    d.answer('act', {'revision': 1, 'status': 'working', 'result': 'submitted', 'submitted': true});
    final s = byName(l, 'codex@api')!;
    await repo.prompt(s, 'add tests');
    expect(d.lastArgs('act'), containsPair('text', 'add tests'));
    await repo.keys(s, ['esc']);
    expect(d.lastArgs('act')['keys'], ['esc']);
    await repo.interrupt(s);
    expect(d.lastArgs('act')['action'], 'interrupt');
    const mux = AgentSession(hostId: 'h', source: SessionSource.tmux, name: 'x');
    await expectLater(repo.keys(mux, ['enter']), throwsA(isA<UnsupportedError>()));
  });

  test('agentd terminal attaches passively with history', () async {
    final l = await until((l) => byName(l, 'codex@api') != null);
    d.on('attach', (c) => c.ok());
    final pty = await repo.terminal(byName(l, 'codex@api')!, cols: 50, rows: 20);
    final a = d.lastArgs('attach');
    expect((a['name'], a['cols'], a['rows'], a['passive'], a['history']), ('codex@api', 50, 20, true, 2000));
    await pty.close();
  });

  test('launch on agentd resolves aliases and paths, and sends the first prompt when ready', () async {
    await until((l) => l.isNotEmpty);
    d.answer('info', {
      'host': 'h',
      'version': '0.7.0',
      'pid': 1,
      'epoch': 'ep1',
      'aliases': [
        {'name': 'webapp', 'dir': '/home/u/src/webapp', 'source': 'file'},
      ],
    });
    d.on('run', (c) => c.ok(sessionInfoJson(name: '${c.args['harness']}@webapp', status: null, state: 'starting')));
    var acts = 0;
    d.on('act', (c) {
      acts++;
      if (acts == 1) return c.fail('session is starting', code: 'not_ready');
      c.ok({'revision': 1, 'status': 'working', 'result': 'submitted', 'submitted': true});
    });

    expect(await repo.projects('h'), ['webapp']);
    final s = await repo.launch(hostId: 'h', where: SessionSource.agentd, project: 'webapp', harness: 'codex', firstPrompt: 'Arregla el login');
    expect(s.name, 'codex@webapp');
    expect(s.status, AgentStatus.starting);
    final run = d.lastArgs('run');
    expect((run['target'], run['harness'], run['cwd']), ('webapp', 'codex', '/home/u'));
    await eventually(() => acts == 2);
    expect(d.lastArgs('act'), containsPair('text', 'Arregla el login'));

    await repo.launch(hostId: 'h', where: SessionSource.agentd, project: '~/src/other', harness: 'claude');
    expect(d.lastArgs('run')['target'], '/home/u/src/other');
  });

  test('projects are empty without agentd', () async {
    await repo.dispose();
    repo = make(caps: testCaps(agentd: false));
    expect(await repo.projects('h'), isEmpty);
  });

  test('zellij sessions are polled while watched', () async {
    await repo.dispose();
    repo = make(caps: testCaps(zellij: true));
    final l = await until((l) => byName(l, 'main') != null);
    expect(byName(l, 'main')!.source, SessionSource.zellij);
    await eventually(() => zellij.lists >= 2);
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    final n = zellij.lists;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(zellij.lists, lessThanOrEqualTo(n + 1));

    final pty = await repo.terminal(byName(l, 'main')!);
    expect(zellij.attached, ['main']);
    await pty.close();

    final launched = await repo.launch(hostId: 'h', where: SessionSource.zellij, project: 'webapp', harness: 'bash');
    expect(launched.name, 'webapp');
    expect(zellij.launched.single.cwd, '~/webapp');
    expect(zellij.launched.single.command, ['sh', '-c', r'exec "${SHELL:-sh}" -l']);
  });

  test('an SSH shell is listed while open and replays its output to a new view', () async {
    final s = await repo.launch(hostId: 'h', where: SessionSource.shell, project: '~/src/api', harness: 'bash');
    expect((s.source, s.name, s.project), (SessionSource.shell, 'ssh-api', 'api'));
    final pty = shell.ptys.single;
    expect(pty.command, r'cd "$HOME"/src/api 2>/dev/null || cd; exec "${SHELL:-sh}" -l');
    var l = await until((l) => byName(l, 'ssh-api') != null);

    pty.emit('user@h:~/src/api\$ ');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final view = await repo.terminal(byName(l, 'ssh-api')!, cols: 60, rows: 20);
    final got = StringBuffer();
    subs.add(view.stream.listen((b) => got.write(utf8.decode(b))));
    await eventually(() => got.toString().contains(r'~/src/api$'));
    view.add(utf8.encode('ls\r'));
    expect(pty.written, ['ls\r']);
    expect(pty.size, (60, 20));
    await view.close(); // detach: the shell keeps running
    l = await until((l) => byName(l, 'ssh-api') != null);

    // A second shell in the same project gets its own name.
    final s2 = await repo.launch(hostId: 'h', where: SessionSource.shell, project: '~/src/api', harness: 'bash');
    expect(s2.name, 'ssh-api-2');

    pty.exit();
    await until((l) => byName(l, 'ssh-api') == null && byName(l, 'ssh-api-2') != null);
  });
}
