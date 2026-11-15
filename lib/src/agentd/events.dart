// Typed events of the agentd event bus (op `subscribe`; agentd AGENTS.md,
// "Event bus"). Every daemon line is `{seq, epoch, time, kind, session?,
// data?}`; [AgentdEvent.parse] picks the subclass by kind. The client adds
// two synthetic events: [SubscribedEvent] on every (re)connect and
// [DisconnectedEvent] when the stream is lost.

import 'dart:convert';

import 'models.dart';

/// Event kinds (`proto.Ev*`).
abstract final class EventKind {
  static const hello = 'hello';
  static const sessionCreated = 'session.created';
  static const sessionStarted = 'session.started';
  static const sessionExited = 'session.exited';
  static const sessionRemoved = 'session.removed';
  static const statusChanged = 'status.changed';
  static const viewChanged = 'view.changed';
  static const inputChanged = 'input.changed';
  static const attentionChanged = 'attention.changed';
  static const mailQueued = 'mail.queued';
  static const mailDelivered = 'mail.delivered';
  static const mailRead = 'mail.read';
  static const mailClaimed = 'mail.claimed';
  static const sessionLabels = 'session.labels';
  static const docChanged = 'doc.changed';
  static const statusReported = 'status.reported';
  static const turnCompleted = 'turn.completed';
  static const resync = 'resync';
  static const heartbeat = 'heartbeat';
  static const bye = 'bye';

  // Synthetic (client side, never on the wire).
  static const subscribed = 'agentd.subscribed';
  static const disconnected = 'agentd.disconnected';
}

/// Base of every event. [seq] is monotonic per [epoch] for bus events and 0
/// for control events (hello, resync, heartbeat, bye) and synthetic ones.
sealed class AgentdEvent {
  const AgentdEvent({required this.kind, this.seq = 0, this.epoch = '', this.time, this.session, this.data});

  final String kind;
  final int seq;
  final String epoch;
  final DateTime? time;
  final String? session;

  /// Raw `data` (decoded JSON), kept for kinds this client does not model.
  final Object? data;

  /// Parses one event line already decoded from JSON.
  static AgentdEvent parse(Json j) {
    final kind = jsonStr(j['kind']);
    final seq = jsonInt(j['seq']);
    final epoch = jsonStr(j['epoch']);
    final time = parseGoTime(j['time']);
    final session = jsonStrOrNull(j['session']);
    final data = j['data'];
    final d = jsonMap(data);
    switch (kind) {
      case EventKind.hello:
        return HelloEvent(epoch: epoch, time: time, data: data, helloEpoch: jsonStr(d['epoch']), helloSeq: jsonInt(d['seq']));
      case EventKind.sessionCreated:
      case EventKind.sessionStarted:
        return SessionInfoEvent(
          kind: kind,
          seq: seq,
          epoch: epoch,
          time: time,
          session: session,
          data: data,
          info: AgentdSessionInfo.fromJson(d),
        );
      case EventKind.sessionExited:
        return SessionExitedEvent(seq: seq, epoch: epoch, time: time, session: session, data: data, exitCode: jsonInt(d['exit_code']));
      case EventKind.sessionRemoved:
        return SessionRemovedEvent(seq: seq, epoch: epoch, time: time, session: session, data: data);
      case EventKind.statusChanged:
        return StatusChangedEvent(
          seq: seq,
          epoch: epoch,
          time: time,
          session: session,
          data: data,
          from: jsonStrOrNull(d['from']),
          status: jsonStr(d['status']),
          reason: jsonStrOrNull(d['reason']),
          attention: jsonBool(d['attention']),
          revision: jsonInt(d['revision']),
          turn: jsonInt(d['turn']),
        );
      case EventKind.viewChanged:
        return ViewChangedEvent(seq: seq, epoch: epoch, time: time, session: session, data: data, revision: jsonInt(d['revision']));
      case EventKind.inputChanged:
        return InputChangedEvent(seq: seq, epoch: epoch, time: time, session: session, data: data, state: jsonStr(d['state']));
      case EventKind.attentionChanged:
        return AttentionChangedEvent(
          seq: seq,
          epoch: epoch,
          time: time,
          session: session,
          data: data,
          attention: jsonBool(d['attention']),
          reason: jsonStrOrNull(d['reason']),
        );
      case EventKind.mailQueued:
      case EventKind.mailDelivered:
      case EventKind.mailRead:
      case EventKind.mailClaimed:
        return MailEvent(
          kind: kind,
          seq: seq,
          epoch: epoch,
          time: time,
          session: session,
          data: data,
          id: jsonInt(d['id']),
          from: jsonStr(d['from']),
          to: jsonStr(d['to']),
          queue: jsonStrOrNull(d['queue']),
          by: jsonStrOrNull(d['by']),
        );
      case EventKind.sessionLabels:
        return SessionLabelsEvent(seq: seq, epoch: epoch, time: time, session: session, data: data, labels: jsonStrMap(d['labels']));
      case EventKind.turnCompleted:
        return TurnCompletedEvent(seq: seq, epoch: epoch, time: time, session: session, data: data, turn: AgentdTurn.fromJson(d));
      case EventKind.resync:
        return ResyncEvent(epoch: epoch, time: time, data: data, reason: jsonStr(d['reason']));
      case EventKind.heartbeat:
        return HeartbeatEvent(epoch: epoch, time: time);
      case EventKind.bye:
        return ByeEvent(epoch: epoch, time: time);
      default:
        // doc.changed, status.reported and future kinds.
        return OtherEvent(kind: kind, seq: seq, epoch: epoch, time: time, session: session, data: data);
    }
  }

  /// Parses one raw event line.
  static AgentdEvent parseLine(String line) => parse(jsonMap(jsonDecode(line)));

  @override
  String toString() => '$runtimeType($kind seq=$seq${session != null ? ' $session' : ''})';
}

/// First line of every stream: the daemon's epoch and last seq.
class HelloEvent extends AgentdEvent {
  const HelloEvent({super.epoch, super.time, super.data, required this.helloEpoch, required this.helloSeq}) : super(kind: EventKind.hello);
  final String helloEpoch;
  final int helloSeq;
}

/// session.created / session.started: data is a SessionInfo.
class SessionInfoEvent extends AgentdEvent {
  const SessionInfoEvent({required super.kind, super.seq, super.epoch, super.time, super.session, super.data, required this.info});
  final AgentdSessionInfo info;
}

class SessionExitedEvent extends AgentdEvent {
  const SessionExitedEvent({super.seq, super.epoch, super.time, super.session, super.data, required this.exitCode})
    : super(kind: EventKind.sessionExited);
  final int exitCode;
}

class SessionRemovedEvent extends AgentdEvent {
  const SessionRemovedEvent({super.seq, super.epoch, super.time, super.session, super.data}) : super(kind: EventKind.sessionRemoved);
}

class StatusChangedEvent extends AgentdEvent {
  const StatusChangedEvent({
    super.seq,
    super.epoch,
    super.time,
    super.session,
    super.data,
    this.from,
    required this.status,
    this.reason,
    this.attention = false,
    this.revision = 0,
    this.turn = 0,
  }) : super(kind: EventKind.statusChanged);
  final String? from;
  final String status;
  final String? reason;
  final bool attention;
  final int revision;
  final int turn;
}

/// The view changed: no content, call `view`.
class ViewChangedEvent extends AgentdEvent {
  const ViewChangedEvent({super.seq, super.epoch, super.time, super.session, super.data, required this.revision})
    : super(kind: EventKind.viewChanged);
  final int revision;
}

class InputChangedEvent extends AgentdEvent {
  const InputChangedEvent({super.seq, super.epoch, super.time, super.session, super.data, required this.state})
    : super(kind: EventKind.inputChanged);
  final String state;
}

class AttentionChangedEvent extends AgentdEvent {
  const AttentionChangedEvent({super.seq, super.epoch, super.time, super.session, super.data, required this.attention, this.reason})
    : super(kind: EventKind.attentionChanged);
  final bool attention;
  final String? reason;
}

/// mail.queued / mail.delivered / mail.read / mail.claimed (never the body).
class MailEvent extends AgentdEvent {
  const MailEvent({
    required super.kind,
    super.seq,
    super.epoch,
    super.time,
    super.session,
    super.data,
    required this.id,
    required this.from,
    required this.to,
    this.queue,
    this.by,
  });
  final int id;
  final String from;
  final String to;
  final String? queue;
  final String? by;
}

class SessionLabelsEvent extends AgentdEvent {
  const SessionLabelsEvent({super.seq, super.epoch, super.time, super.session, super.data, required this.labels})
    : super(kind: EventKind.sessionLabels);
  final Map<String, String> labels;
}

class TurnCompletedEvent extends AgentdEvent {
  const TurnCompletedEvent({super.seq, super.epoch, super.time, super.session, super.data, required this.turn})
    : super(kind: EventKind.turnCompleted);
  final AgentdTurn turn;
}

/// Events were lost (reason overflow | since_seq_too_old | epoch_mismatch):
/// the caller must reload its state (`ls`, views) and keep consuming.
class ResyncEvent extends AgentdEvent {
  const ResyncEvent({super.epoch, super.time, super.data, required this.reason}) : super(kind: EventKind.resync);
  final String reason;
}

class HeartbeatEvent extends AgentdEvent {
  const HeartbeatEvent({super.epoch, super.time}) : super(kind: EventKind.heartbeat);
}

/// The daemon is shutting down; the stream ends after it.
class ByeEvent extends AgentdEvent {
  const ByeEvent({super.epoch, super.time}) : super(kind: EventKind.bye);
}

/// Any other kind (doc.changed, status.reported, future kinds): see [data].
class OtherEvent extends AgentdEvent {
  const OtherEvent({required super.kind, super.seq, super.epoch, super.time, super.session, super.data});
}

/// Synthetic: a (re)connection succeeded. [result] is the subscribe answer
/// (fresh session snapshot). [reconnect] is false only for the first
/// connection. [resumed] says the daemon was asked to replay from the last
/// seen seq; [epochChanged] that the daemon restarted since the last
/// connection (revisions and seqs restarted: reload everything).
class SubscribedEvent extends AgentdEvent {
  SubscribedEvent({required this.result, this.reconnect = false, this.resumed = false, this.epochChanged = false})
    : super(kind: EventKind.subscribed, seq: result.seq, epoch: result.epoch);
  final AgentdSubscribeResult result;
  final bool reconnect;
  final bool resumed;
  final bool epochChanged;
}

/// Synthetic: the stream was lost; a reconnect follows after [retryIn]
/// (null when the subscription is not reconnecting).
class DisconnectedEvent extends AgentdEvent {
  const DisconnectedEvent({this.error, this.retryIn}) : super(kind: EventKind.disconnected);
  final Object? error;
  final Duration? retryIn;
}
