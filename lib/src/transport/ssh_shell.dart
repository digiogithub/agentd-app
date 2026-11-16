// RemoteShell over one authenticated dartssh2 SSHClient.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../core/contracts.dart';
import 'quote.dart';

/// [RemoteShell] backed by an authenticated [SSHClient].
///
/// Commands run through `sh -lc` so the login profile (PATH with
/// `~/.local/bin`, Homebrew...) is in effect, as in an interactive login.
class SshRemoteShell implements RemoteShell {
  SshRemoteShell(this.client, {required this.hostId, this.hostKeyFingerprint, this.newHostKey = false});

  final SSHClient client;
  final String hostId;

  /// Fingerprint of the key the host presented (`SHA256:...`).
  final String? hostKeyFingerprint;

  /// True when [hostKeyFingerprint] was accepted on this connect (trust on
  /// first use): the caller should save it in the host's config.
  final bool newHostKey;

  /// Completes when the SSH connection ends, for whatever reason.
  Future<void> get done => client.done.catchError((_) {});

  @override
  bool get isClosed => client.isClosed;

  @override
  Future<ExecResult> exec(String command, {Duration timeout = const Duration(seconds: 30), String? stdin}) async {
    final session = await client.execute('sh -lc ${shellQuote(command)}').timeout(timeout);
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    final outSub = session.stdout.listen(out.add, onDone: outDone.complete, onError: (Object e) {
      if (!outDone.isCompleted) outDone.complete();
    });
    final errSub = session.stderr.listen(err.add, onDone: errDone.complete, onError: (Object e) {
      if (!errDone.isCompleted) errDone.complete();
    });

    if (stdin != null && stdin.isNotEmpty) {
      session.write(Uint8List.fromList(utf8.encode(stdin)));
    }
    await session.stdin.close();

    try {
      await Future.wait([outDone.future, errDone.future, session.done]).timeout(timeout);
    } on TimeoutException {
      await outSub.cancel();
      await errSub.cancel();
      session.close();
      rethrow;
    }
    // exit-status normally precedes the channel close; give it a moment.
    final code = session.exitCode ?? await session.waitForExit(timeout: const Duration(milliseconds: 200));
    return ExecResult(
      code,
      utf8.decode(out.takeBytes(), allowMalformed: true),
      utf8.decode(err.takeBytes(), allowMalformed: true),
    );
  }

  @override
  Future<PtySession> pty({String? command, int cols = 80, int rows = 24, Map<String, String> env = const {}}) async {
    final ptyConfig = SSHPtyConfig(type: 'xterm-256color', width: cols, height: rows);
    final SSHSession session;
    if (command == null && env.isEmpty) {
      session = await client.shell(pty: ptyConfig);
    } else {
      session = await client.execute(ptyCommand(command: command, env: env), pty: ptyConfig);
    }
    return SshPtySession(session);
  }

  @override
  Future<ByteChannel> openUnixSocket(String path) async {
    final forward = await client.forwardLocalUnix(path);
    return SshByteChannel(forward);
  }

  @override
  Future<void> writeFile(
    String path,
    Uint8List data, {
    int mode = 0x180,
  }) async {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', 'must be absolute');
    }
    try {
      await _writeSftp(path, data, mode);
    } on SftpError {
      await _writeExec(path, data, mode);
    } on SSHChannelOpenError {
      await _writeExec(path, data, mode);
    } on SSHChannelRequestError {
      await _writeExec(path, data, mode);
    }
  }

  Future<void> _writeSftp(String path, Uint8List data, int mode) async {
    final sftp = await client.sftp();
    try {
      final slash = path.lastIndexOf('/');
      if (slash > 0) {
        var dir = '';
        for (final part in path.substring(1, slash).split('/')) {
          if (part.isEmpty) continue;
          dir = '$dir/$part';
          try {
            await sftp.stat(dir);
          } on SftpStatusError {
            await sftp.mkdir(
              dir,
              SftpFileAttrs(mode: SftpFileMode.value(0x1C0)),
            ); // 0700
          }
        }
      }
      final file = await sftp.open(
        path,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(data);
      } finally {
        await file.close();
      }
      await sftp.setStat(path, SftpFileAttrs(mode: SftpFileMode.value(mode)));
    } finally {
      sftp.close();
    }
  }

  /// Fallback when the SFTP subsystem is unavailable: base64 on stdin, decoded
  /// by `base64 -d` (GNU, newer macOS) or `base64 -D` (older macOS).
  Future<void> _writeExec(String path, Uint8List data, int mode) async {
    final slash = path.lastIndexOf('/');
    final dir = slash > 0 ? path.substring(0, slash) : '/';
    final b = base64Encode(data);
    final wrapped = StringBuffer();
    for (var i = 0; i < b.length; i += 76) {
      wrapped.writeln(b.substring(i, i + 76 > b.length ? b.length : i + 76));
    }
    final q = shellQuote(path);
    final cmd =
        'umask 077; mkdir -p ${shellQuote(dir)} && { base64 -d 2>/dev/null || base64 -D; } > $q && chmod ${mode.toRadixString(8)} $q';
    final r = await exec(
      cmd,
      timeout: const Duration(minutes: 2),
      stdin: wrapped.toString(),
    );
    if (!r.ok) {
      final err = r.stderr.trim();
      throw StateError(
        'no se pudo escribir el fichero en el host${err.isEmpty ? '' : ': $err'}',
      );
    }
  }

  @override
  Future<void> close() async {
    client.close();
    await done;
  }
}

/// Remote command line for a PTY: [env] exported first (sshd usually
/// refuses `env` channel requests), then [command] through `sh -lc`, or the
/// user's login shell when [command] is null.
String ptyCommand({String? command, Map<String, String> env = const {}}) {
  final b = StringBuffer();
  for (final e in env.entries) {
    if (!_envName.hasMatch(e.key)) {
      throw ArgumentError.value(e.key, 'env', 'invalid environment variable name');
    }
    b.write('export ${e.key}=${shellQuote(e.value)}; ');
  }
  if (command == null) {
    b.write(r'exec "${SHELL:-sh}" -l');
  } else {
    b.write('exec sh -lc ${shellQuote(command)}');
  }
  return 'sh -c ${shellQuote(b.toString())}';
}

final _envName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// [ByteChannel] over an SSH channel (here: `direct-streamlocal` to a unix
/// socket). [stream] is single-subscription.
class SshByteChannel implements ByteChannel {
  SshByteChannel(this._socket) : stream = _socket.stream;

  final SSHSocket _socket;

  @override
  final Stream<Uint8List> stream;

  @override
  void add(List<int> data) => _socket.sink.add(data);

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {
      // Already closed or the connection went away.
    }
  }

  @override
  Future<void> get done => _socket.done.catchError((_) {});
}

/// [PtySession] over a dartssh2 [SSHSession] started with a PTY. stdout and
/// stderr are merged into [stream] (single-subscription).
class SshPtySession implements PtySession {
  SshPtySession(this.session) {
    var open = 2;
    void finish() {
      if (--open == 0) _out.close();
    }

    _out = StreamController<Uint8List>(
      onListen: () {
        _subs = [
          session.stdout.listen(_out.add, onError: _out.addError, onDone: finish),
          session.stderr.listen(_out.add, onError: _out.addError, onDone: finish),
        ];
      },
      onPause: () {
        for (final s in _subs) {
          s.pause();
        }
      },
      onResume: () {
        for (final s in _subs) {
          s.resume();
        }
      },
      onCancel: () async {
        for (final s in _subs) {
          await s.cancel();
        }
      },
    );
  }

  final SSHSession session;
  late final StreamController<Uint8List> _out;
  List<StreamSubscription<Uint8List>> _subs = const [];

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  void add(List<int> data) => session.write(data is Uint8List ? data : Uint8List.fromList(data));

  @override
  void resize(int cols, int rows) => session.resizeTerminal(cols, rows);

  @override
  Future<int?> get exitCode => session.waitForExit();

  @override
  Future<void> close() async => session.close();

  @override
  Future<void> get done => session.done.catchError((_) {});
}
