import 'dart:async';

import '../core/contracts.dart';
import 'detect.dart';
import 'steps.dart';

class ProvisionException implements Exception {
  ProvisionException(this.message, {this.result});
  final String message;
  final ExecResult? result;

  @override
  String toString() => 'ProvisionException: $message';
}

/// [ProvisionService] over a [RemoteShell]: detection is one script, and
/// installs run the scripts of [buildPlan] one by one.
class DefaultProvisionService implements ProvisionService {
  const DefaultProvisionService({this.detectTimeout = const Duration(seconds: 90)});

  /// The detect script probes ten tools with 5 s each at most.
  final Duration detectTimeout;

  @override
  Future<HostCapabilities> detect(RemoteShell shell) async => (await detectReport(shell)).capabilities;

  /// Like [detect], with everything the script reported (login PATH, home,
  /// live sockets...).
  Future<DetectReport> detectReport(RemoteShell shell) async {
    final r = await shell.exec(detectScript, timeout: detectTimeout);
    final report = parseDetect(r.stdout);
    if (report.os.isEmpty) {
      throw ProvisionException('host detection failed (exit ${r.exitCode}): ${_tail(r.stderr)}', result: r);
    }
    return report;
  }

  /// The plan with titles and step kinds, for the UI.
  @override
  List<PlannedStep> planSteps(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) =>
      buildPlan(caps, agentd: agentd, hcListener: hcListener, mcp: mcp, clis: clis);

  @override
  List<String> plan(HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) =>
      [for (final s in planSteps(caps, agentd: agentd, hcListener: hcListener, mcp: mcp, clis: clis)) s.command];

  /// Runs the plan. Per step: one event when it starts (`done: false`, no
  /// error), then one with `done: true` (message = last output line) or
  /// one with `error` set. A failed step stops the rest of its group
  /// (download → verify → install) and every step that needs that group
  /// (service, hc listener and MCP need agentd; MCP for a CLI needs that
  /// CLI); those get one event with `skipped: true`. Independent steps keep
  /// going.
  @override
  Stream<ProvisionEvent> install(RemoteShell shell, HostCapabilities caps, {bool agentd = true, bool hcListener = true, bool mcp = true, Set<String> clis = const {}}) async* {
    final failed = <String, String>{}; // group -> title of the failed step
    for (final s in planSteps(caps, agentd: agentd, hcListener: hcListener, mcp: mcp, clis: clis)) {
      final blocker = failed.containsKey(s.group) ? s.group : s.needs.firstWhere(failed.containsKey, orElse: () => '');
      if (blocker.isNotEmpty) {
        yield ProvisionEvent(s.step, s.title, skipped: true);
        failed.putIfAbsent(s.group, () => s.title);
        continue;
      }
      yield ProvisionEvent(s.step, s.title);
      ExecResult r;
      try {
        r = await shell.exec(s.command, timeout: s.timeout);
      } catch (e) {
        failed[s.group] = s.title;
        yield ProvisionEvent(s.step, s.title, error: e.toString());
        continue;
      }
      if (r.ok) {
        yield ProvisionEvent(s.step, _lastLine(r.stdout) ?? s.title, done: true);
      } else {
        failed[s.group] = s.title;
        final why = _tail(r.stderr.trim().isNotEmpty ? r.stderr : r.stdout);
        yield ProvisionEvent(s.step, s.title, error: 'exit ${r.exitCode ?? '?'}${why.isEmpty ? '' : ': $why'}');
      }
    }
  }
}

String? _lastLine(String s) {
  final lines = s.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  return lines.isEmpty ? null : lines.last;
}

/// The last few non-empty lines of [s], for error messages.
String _tail(String s, {int lines = 5}) {
  final l = s.split('\n').map((x) => x.trimRight()).where((x) => x.trim().isNotEmpty).toList();
  return l.skip(l.length > lines ? l.length - lines : 0).join('\n');
}
