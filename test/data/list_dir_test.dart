import 'dart:io';

import 'package:agentd_app/src/core/contracts.dart';
import 'package:agentd_app/src/data/list_dir.dart';
import 'package:flutter_test/flutter_test.dart';

String out(List<String> fields) =>
    '@@agentd-ls\u0000${fields.join('\u0000')}\u0000';

void main() {
  group('parseListDir', () {
    test('path, home and entries sorted case-insensitively', () {
      final l = parseListDir(
        out([
          '/home/u',
          '/home/u',
          'beta',
          '1',
          'Alpha',
          '1',
          'locked',
          '0',
          'alpha2',
          '1',
        ]),
        exitCode: 0,
      );
      expect((l.path, l.home), ('/home/u', '/home/u'));
      expect(l.entries.map((e) => e.name), [
        'Alpha',
        'alpha2',
        'beta',
        'locked',
      ]);
      expect(l.entries.last.enterable, isFalse);
      expect(l.truncated, isFalse);
    });

    test('names may contain spaces, quotes and newlines; junk before the marker is ignored', () {
      final l = parseListDir(
        'motd\n${out(['/', '/root', 'a b', '1', "it's", '1', 'x\ny', '0'])}',
        exitCode: 0,
      );
      expect(l.entries.map((e) => e.name), ['a b', "it's", 'x\ny']);
    });

    test('truncated record', () {
      final l = parseListDir(out(['/', '/h', 'a', '1', '', 'T']), exitCode: 0);
      expect(l.truncated, isTrue);
      expect(l.entries.single.name, 'a');
    });

    test('typed errors', () {
      expect(
        () => parseListDir('', exitCode: 3, requested: '/nope'),
        throwsA(
          isA<ListDirException>()
              .having((e) => e.failure, 'f', ListDirFailure.notFound)
              .having((e) => e.message, 'm', 'No existe'),
        ),
      );
      expect(
        () => parseListDir('', exitCode: 4),
        throwsA(
          isA<ListDirException>()
              .having((e) => e.failure, 'f', ListDirFailure.noPermission)
              .having((e) => e.message, 'm', 'Sin permiso'),
        ),
      );
      expect(
        () => parseListDir('garbage', exitCode: 0),
        throwsA(isA<ListDirException>()),
      );
      expect(
        () => parseListDir('', exitCode: 1, stderr: 'boom'),
        throwsA(isA<ListDirException>()),
      );
    });
  });

  group('listDirScript under sh', () {
    late Directory tmp;
    final root =
        Platform.isLinux &&
        Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('listdir');
      for (final n in [
        'plain',
        'with space',
        "it's",
        'new\nline',
        '.hidden',
        'Zed',
        'apple',
      ]) {
        Directory('${tmp.path}/$n').createSync();
      }
      File('${tmp.path}/file.txt').writeAsStringSync('x');
      Link('${tmp.path}/link').createSync('${tmp.path}/plain');
      Link('${tmp.path}/broken').createSync('${tmp.path}/missing');
      Directory('${tmp.path}/locked').createSync();
      Process.runSync('chmod', ['000', '${tmp.path}/locked']);
    });

    tearDown(() {
      Process.runSync('chmod', ['755', '${tmp.path}/locked']);
      tmp.deleteSync(recursive: true);
    });

    Future<DirListing> run(
      String path, {
      bool hidden = false,
      String? home,
      int cap = listDirCap,
    }) async {
      final r = await Process.run(
        'sh',
        ['-c', listDirScript(path, hidden: hidden, cap: cap)],
        environment: {'HOME': home ?? tmp.path},
        stdoutEncoding: null,
      );
      final stdout = String.fromCharCodes(r.stdout as List<int>);
      return parseListDir(
        stdout,
        exitCode: r.exitCode,
        stderr: r.stderr.toString(),
        requested: path,
      );
    }

    test('lists directories only (symlinks to directories included), hidden on demand', () async {
      final l = await run(tmp.path);
      final dir = await Directory(tmp.path).resolveSymbolicLinks();
      expect(l.path == tmp.path || l.path == dir, isTrue);
      expect(l.home, tmp.path);
      expect(
        l.entries.map((e) => e.name),
        [
          'apple',
          'link',
          'locked',
          'new\nline',
          'it\'s',
          'plain',
          'with space',
          'Zed',
        ].toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
      );
      expect(l.entries.map((e) => e.name), isNot(contains('file.txt')));
      expect(l.entries.map((e) => e.name), isNot(contains('broken')));
      expect(l.entries.map((e) => e.name), isNot(contains('.hidden')));

      final h = await run(tmp.path, hidden: true);
      expect(h.entries.map((e) => e.name), contains('.hidden'));
    });

    test('a mode 000 folder is listed but not enterable', () async {
      final l = await run(tmp.path);
      final e = l.entries.firstWhere((e) => e.name == 'locked');
      expect(e.enterable, root); // root can enter anything
      expect(l.entries.firstWhere((e) => e.name == 'plain').enterable, isTrue);
    }, skip: root ? 'runs as root' : null);

    test(
      'empty path is the home directory; a hostile path is only data',
      () async {
        final l = await run('', home: '${tmp.path}/with space');
        expect(l.path.endsWith('with space'), isTrue);
        expect(l.entries, isEmpty);
        await expectLater(
          run("/tmp/x'; touch ${tmp.path}/pwned; '"),
          throwsA(
            isA<ListDirException>().having(
              (e) => e.failure,
              'f',
              ListDirFailure.notFound,
            ),
          ),
        );
        expect(File('${tmp.path}/pwned').existsSync(), isFalse);
      },
    );

    test('missing and unreadable folders are typed errors', () async {
      await expectLater(
        run('${tmp.path}/nope'),
        throwsA(
          isA<ListDirException>().having(
            (e) => e.failure,
            'f',
            ListDirFailure.notFound,
          ),
        ),
      );
      if (!root) {
        await expectLater(
          run('${tmp.path}/locked'),
          throwsA(
            isA<ListDirException>().having(
              (e) => e.failure,
              'f',
              ListDirFailure.noPermission,
            ),
          ),
        );
      }
    });

    test('the cap marks the listing as truncated', () async {
      final l = await run(tmp.path, cap: 3);
      expect(l.entries, hasLength(3));
      expect(l.truncated, isTrue);
    });
  });
}
