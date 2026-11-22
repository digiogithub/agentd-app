// AgentdClient: the daemon ops over fresh connections (one per request,
// like the Go client; subscribe and attach upgrade their own connection).

import 'dart:async';

import '../core/contracts.dart';
import 'attach.dart';
import 'codec.dart';
import 'errors.dart';
import 'models.dart';
import 'subscription.dart';
import 'wire.dart';

/// Opens a new channel to the daemon socket (e.g. an SSH
/// `direct-streamlocal` channel).
typedef AgentdDial = Future<ByteChannel> Function();

/// Abstract key names accepted by act keys (agentd AGENTS.md, "Act").
abstract final class AgentdKeys {
  static const enter = 'enter';
  static const esc = 'esc';
  static const tab = 'tab';
  static const shiftTab = 'shift-tab';
  static const up = 'up';
  static const down = 'down';
  static const left = 'left';
  static const right = 'right';
  static const backspace = 'backspace';
  static const space = 'space';
  static const ctrlC = 'ctrl-c';
}

/// Client of the agentd daemon protocol. Every op dials a new connection,
/// writes one request line, reads one answer line and closes. Daemon
/// refusals throw [AgentdError]; channel / protocol failures and timeouts
/// throw [AgentdTransportError].
///
/// Args sent are exactly the daemon's field names: the daemon rejects
/// unknown fields.
class AgentdClient {
  AgentdClient(
    this.dial, {
    this.timeout = const Duration(seconds: 30),
    this.actTimeout = const Duration(seconds: 90),
    this.clientName = 'agentd-app',
  });

  final AgentdDial dial;

  /// Per-request deadline (dial + answer).
  final Duration timeout;

  /// Deadline for act (the daemon may wait for a lock, verify a paste,
  /// step through a menu).
  final Duration actTimeout;

  /// Sent as act `client` (audit log only, never trusted).
  final String clientName;

  /// Runs [op] with [args] and returns the answer's `data`.
  Future<Object?> call(String op, [Map<String, Object?>? args, Duration? deadline]) async {
    final d = deadline ?? timeout;
    final req = encodeRequest(op, args);
    WireConnection? conn;
    var abandoned = false;
    try {
      return await () async {
        final ch = await dial();
        if (abandoned) {
          await ch.close();
          throw AgentdTransportError('$op: abandoned');
        }
        conn = WireConnection(ch);
        conn!.write(req);
        final String line;
        try {
          line = await conn!.lines.first;
        } on StateError {
          throw AgentdTransportError('$op: connection closed before the answer');
        }
        return decodeResponse(line, op: op);
      }().timeout(
        d,
        onTimeout: () {
          abandoned = true;
          throw AgentdTransportError('$op: no answer within ${d.inSeconds}s');
        },
      );
    } on AgentdError {
      rethrow;
    } on AgentdTransportError {
      rethrow;
    } catch (e) {
      throw AgentdTransportError('$op failed', cause: e);
    } finally {
      await conn?.close();
    }
  }

  Future<Json> _callMap(String op, [Map<String, Object?>? args, Duration? deadline]) async => jsonMap(await call(op, args, deadline));

  // ---- Daemon ----

  Future<AgentdPing> ping() async => AgentdPing.fromJson(await _callMap('ping'));

  Future<AgentdInfo> info() async => AgentdInfo.fromJson(await _callMap('info'));

  // ---- Sessions ----

  Future<List<AgentdSessionInfo>> ls() async {
    final r = await _callMap('ls');
    return [for (final s in (r['sessions'] as List?) ?? const []) AgentdSessionInfo.fromJson(jsonMap(s))];
  }

  /// Starts a session. With [target] (alias or absolute directory) and
  /// [harness] the daemon resolves cwd, command, name (`<harness>@<label>`)
  /// and profile like the CLI. [cols]/[rows] null = the profile's size.
  /// A relative [target] needs an absolute [cwd].
  Future<AgentdSessionInfo> run({
    String? target,
    String? harness,
    String? cwd,
    String? name,
    List<String> cmd = const [],
    Map<String, String> env = const {},
    String? profile,
    int? cols,
    int? rows,
    Map<String, String> labels = const {},
  }) async {
    final args = compactArgs(
      {
        'name': name ?? '',
        'target': target,
        'harness': harness,
        'cwd': cwd,
        'cmd': cmd,
        'env': env,
        'profile': profile,
        'cols': cols,
        'rows': rows,
        'labels': labels,
      },
      keep: {'name'},
    );
    return AgentdSessionInfo.fromJson(await _callMap('run', args, timeout * 2));
  }

  /// Signals a session ([signal] "" = TERM; e.g. "HUP", "KILL", "9").
  Future<void> kill(String name, {String? signal}) => call('kill', compactArgs({'name': name, 'signal': signal}, keep: {'name'}));

  /// Removes an exited session.
  Future<void> rm(String name) => call('rm', {'name': name});

  /// Semantic view. With [sinceRevision] + [epoch] still current the answer
  /// has `notModified` and only name/epoch/revision.
  Future<AgentdView> view(String name, {int? sinceRevision, String? epoch, int? linesLimit, int? fromLine, bool scrollback = false, bool markup = false}) async {
    final args = <String, Object?>{
      'name': name,
      if (sinceRevision != null && sinceRevision > 0) 'since_revision': sinceRevision,
      if (epoch != null && epoch.isNotEmpty) 'epoch': epoch,
      if (linesLimit != null && linesLimit > 0) 'lines_limit': linesLimit,
      'from_line': ?fromLine,
      if (scrollback) 'scrollback': true,
      if (markup && !_noMarkup) 'markup': true,
    };
    final Map<String, Object?> raw;
    try {
      raw = await _callMap('view', args);
    } on AgentdError catch (e) {
      // A daemon before 0.6.3 rejects the unknown "markup" argument: ask
      // without it from now on and escape its plain text.
      if (args.containsKey('markup') && e.code == AgentdErrorCode.invalid && e.message.contains('markup')) {
        _noMarkup = true;
        return view(name, sinceRevision: sinceRevision, epoch: epoch, linesLimit: linesLimit, fromLine: fromLine, scrollback: scrollback, markup: true);
      }
      rethrow;
    }
    if (markup && _noMarkup && raw['lines'] is List) {
      raw['lines'] = [
        for (final l in raw['lines'] as List)
          if (l is Map && l['text'] is String) {...l, 'md': escapeMarkup(l['text'] as String)} else l,
      ];
    }
    return AgentdView.fromJson(raw, name: name);
  }

  /// The daemon rejected view markup (agentd before 0.6.3).
  bool _noMarkup = false;

  /// Clears a session's attention flag; returns the view revision.
  Future<int> viewAck(String name) async => jsonInt((await _callMap('view_ack', {'name': name}))['revision']);

  /// Finished turns, oldest first (at most 100).
  Future<List<AgentdTurn>> turns(String name) async {
    final r = await _callMap('turns', {'name': name});
    return [for (final t in (r['turns'] as List?) ?? const []) AgentdTurn.fromJson(jsonMap(t))];
  }

  /// Merges [labels] (an empty value removes the key); returns all labels.
  Future<Map<String, String>> label(String name, Map<String, String> labels) async =>
      jsonStrMap((await _callMap('label', {'name': name, 'labels': labels}))['labels']);

  // ---- Act ----

  /// Raw act. Prefer the typed helpers below. A `conflict` error carries
  /// `{revision, view}` in [AgentdError.data] (see [conflictView]).
  Future<AgentdActResult> act(
    String name,
    String action, {
    String? text,
    bool? submit,
    String? optionId,
    String? label,
    int? revision,
    String? epoch,
    List<String> keys = const [],
    bool force = false,
  }) async {
    final args = <String, Object?>{
      'name': name,
      'action': action,
      'text': ?text,
      'submit': ?submit,
      if (optionId != null && optionId.isNotEmpty) 'option_id': optionId,
      if (label != null && label.isNotEmpty) 'label': label,
      if (revision != null && revision > 0) 'revision': revision,
      if (epoch != null && epoch.isNotEmpty && revision != null && revision > 0) 'epoch': epoch,
      if (keys.isNotEmpty) 'keys': keys,
      if (clientName.isNotEmpty) 'client': clientName,
      if (force) 'force': true,
    };
    return AgentdActResult.fromJson(await _callMap('act', args, actTimeout));
  }

  /// Types [text] and (by default) submits it. Pass the [revision] and
  /// [epoch] of the view the user acted on so a changed screen is refused.
  Future<AgentdActResult> prompt(String name, String text, {bool submit = true, int? revision, String? epoch, bool force = false}) =>
      act(name, 'prompt', text: text, submit: submit ? null : false, revision: revision, epoch: epoch, force: force);

  /// Picks a menu option. [revision] and [epoch] (from the view) are required.
  Future<AgentdActResult> choose(
    String name,
    String optionId, {
    String? label,
    required int revision,
    required String epoch,
    bool force = false,
  }) => act(name, 'choose', optionId: optionId, label: label, revision: revision, epoch: epoch, force: force);

  /// Sends abstract keys (see [AgentdKeys]), 1..32.
  Future<AgentdActResult> keys(String name, List<String> keys, {int? revision, String? epoch, bool force = false}) =>
      act(name, 'keys', keys: keys, revision: revision, epoch: epoch, force: force);

  Future<AgentdActResult> interrupt(String name, {int? revision, String? epoch, bool force = false}) =>
      act(name, 'interrupt', revision: revision, epoch: epoch, force: force);

  Future<AgentdActResult> cancel(String name, {int? revision, String? epoch, bool force = false}) =>
      act(name, 'cancel', revision: revision, epoch: epoch, force: force);

  /// The fresh view carried by an act `conflict` error, if any.
  static AgentdView? conflictView(AgentdError e) {
    if (!e.isConflict || e.data is! Map) return null;
    final v = jsonMap(e.data)['view'];
    return v is Map ? AgentdView.fromJson(jsonMap(v)) : null;
  }

  // ---- Mailbox ----

  /// Sends a message as the caller (`human:<user>`). [to] is a session,
  /// `human:<name>` or `queue:<name>`.
  Future<AgentdMessage> send({required String to, required String body, String subject = '', int? replyTo}) async {
    final args = compactArgs({'to': to, 'subject': subject, 'body': body, 'reply_to': replyTo}, keep: {'to', 'body'});
    return AgentdMessage.fromJson(await _callMap('send', args));
  }

  /// The caller's inbox ([all] includes read messages). [as] peeks at
  /// another mailbox without changing states. [sinceDigest] = cheap poll.
  Future<AgentdInbox> inbox({String? as, bool all = false, String? sinceDigest}) async =>
      AgentdInbox.fromJson(await _callMap('inbox', compactArgs({'as': as, 'all': all, 'since_digest': sinceDigest})));

  /// Reads (and marks read) message [id]; with [as] a peek.
  Future<AgentdMessage> read(int id, {String? as}) async =>
      AgentdMessage.fromJson(await _callMap('read', compactArgs({'as': as, 'id': id}, keep: {'id'})));

  /// Replies to message [id] (a reply closes a question). With [notify]
  /// false the reply is stored as delivered and never typed into the
  /// session: for an answer the agent already got another way (its prompt).
  Future<AgentdMessage> reply(int id, String body, {bool notify = true}) async =>
      AgentdMessage.fromJson(await _callMap('reply', {'id': id, 'body': body, if (!notify) 'notify': false}));

  /// Without [name]: every non-empty queue. With [name]: its unclaimed items
  /// (bodies only with [bodies]).
  Future<AgentdQueueResult> queue({String? name, bool bodies = false, String? sinceDigest}) async =>
      AgentdQueueResult.fromJson(await _callMap('queue', compactArgs({'name': name, 'bodies': bodies, 'since_digest': sinceDigest})));

  // ---- Work dashboard ----

  /// Everything a dashboard paints for this host: every session with its
  /// task list and the open questions it asked the caller. With
  /// [sinceDigest] still current the answer is `notModified` + the digest.
  /// Humans and relay devices only (a guest device gets no questions).
  Future<AgentdBoard> board({String? sinceDigest}) async =>
      AgentdBoard.fromJson(await _callMap('board', compactArgs({'since_digest': sinceDigest})));

  /// The task list of session [name] (agents write it; humans only read).
  Future<AgentdTasksResult> tasks(String name) async => AgentdTasksResult.fromJson(await _callMap('tasks', {'name': name}));

  // ---- Streams ----

  /// Opens a resilient event subscription (see [AgentdSubscription]).
  /// Listening to the returned stream connects; cancelling closes.
  AgentdSubscription subscribe({
    List<String> sessions = const [],
    List<String> kinds = const [],
    int? sinceSeq,
    String? epoch,
    int? heartbeatMs,
    bool reconnect = true,
    Duration minBackoff = const Duration(milliseconds: 500),
    Duration maxBackoff = const Duration(seconds: 30),
    Duration? idleTimeout,
  }) => AgentdSubscription(
    dial,
    sessions: sessions,
    kinds: kinds,
    sinceSeq: sinceSeq ?? 0,
    epoch: epoch,
    heartbeatMs: heartbeatMs,
    reconnect: reconnect,
    minBackoff: minBackoff,
    maxBackoff: maxBackoff,
    idleTimeout: idleTimeout,
  );

  /// Attaches to session [name]. [observe]: watch only. [passive]: take
  /// size ownership only after input/resize/focus. [history]: scrollback
  /// lines painted first (<= 10000).
  Future<AgentdPtySession> attach(
    String name, {
    int cols = 80,
    int rows = 24,
    bool observe = false,
    bool passive = false,
    int history = 0,
  }) async {
    final args = compactArgs(
      {
        'name': name,
        'cols': cols.clamp(0, 0xffff),
        'rows': rows.clamp(0, 0xffff),
        'observe': observe,
        'passive': passive,
        'history': history.clamp(0, 10000),
      },
      keep: {'name'},
    );
    final req = encodeRequest('attach', args);
    final ch = await dial().timeout(timeout, onTimeout: () => throw const AgentdTransportError('attach: dial timeout'));
    final conn = WireConnection(ch, rawAfterFirstLine: true);
    try {
      conn.write(req);
      final String line;
      try {
        line = await conn.lines.first.timeout(timeout);
      } on StateError {
        throw const AgentdTransportError('attach: connection closed before the answer');
      } on TimeoutException {
        throw const AgentdTransportError('attach: no answer');
      }
      decodeResponse(line, op: 'attach');
      return AgentdPtySession(conn, observe: observe);
    } catch (_) {
      await conn.close();
      rethrow;
    }
  }
}

/// [text] as chat markup that shows as itself (the escaping agentd's
/// screen.Markup applies), for daemons that send no `md`.
String escapeMarkup(String text) {
  final b = StringBuffer();
  for (final r in text.runes) {
    final c = String.fromCharCode(r);
    if (r < 128 && r'\*_`[]<>|~#&'.contains(c)) b.write(r'\');
    b.write(c);
  }
  var out = b.toString();
  final t = out.trim();
  if (t.isNotEmpty && t.replaceAll(RegExp(r'[-= ]'), '').isEmpty) {
    final i = out.indexOf(RegExp(r'[-=]'));
    out = '${out.substring(0, i)}\\${out.substring(i)}';
  }
  return out;
}
