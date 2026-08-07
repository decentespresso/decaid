import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/webui_support/webui_zip_support.dart';

/// Tests for the pure helpers that back WebUIStorage zip handling.
///
/// Covers:
///   - sanitizeZipEntryPath (issue #147 — Win32-reserved chars)
///   - extractArchiveToDirectory (issue #147 — per-entry error isolation)
///   - installBundledSkinList (issue #148 — per-skin loop continuation)
void main() {
  group('sanitizeZipEntryPath', () {
    test('leaves a normal filename unchanged', () {
      expect(sanitizeZipEntryPath('style.css'), 'style.css');
    });

    test('leaves a nested normal path unchanged', () {
      expect(
        sanitizeZipEntryPath('assets/images/logo.png'),
        'assets/images/logo.png',
      );
    });

    test('replaces a colon in a filename with underscore', () {
      expect(
        sanitizeZipEntryPath('shots/2025-09-12T16:04:38.049213.json'),
        'shots/2025-09-12T16_04_38.049213.json',
      );
    });

    test('replaces all Win32-reserved chars in a segment', () {
      expect(
        sanitizeZipEntryPath('a<b>c:d"e|f?g*h.txt'),
        'a_b_c_d_e_f_g_h.txt',
      );
    });

    test('preserves forward-slash path separators between segments', () {
      expect(
        sanitizeZipEntryPath('dir/sub:dir/file:name.txt'),
        'dir/sub_dir/file_name.txt',
      );
    });

    test('strips trailing dots from each path segment', () {
      // Win32 silently drops trailing dots from path components; force them
      // out so later reads resolve the same path we wrote. Embedded dots
      // (e.g. `file.tar.gz`) are valid and must survive untouched.
      expect(sanitizeZipEntryPath('weird./file.tar.gz'), 'weird/file.tar.gz');
      expect(
        sanitizeZipEntryPath('trailing.../normal.txt'),
        'trailing/normal.txt',
      );
    });

    test('strips trailing spaces from each path segment', () {
      expect(sanitizeZipEntryPath('dir /file.txt '), 'dir/file.txt');
    });

    test('leaves an empty string as empty', () {
      expect(sanitizeZipEntryPath(''), '');
    });
  });

  group('extractArchiveToDirectory', () {
    late Directory tempDir;
    late Logger testLog;
    late List<LogRecord> logged;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'reaprime_zip_support_test_',
      );
      testLog = Logger.detached('ExtractTest');
      logged = <LogRecord>[];
      testLog.onRecord.listen(logged.add);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('extracts a single file with its content intact', () {
      final archive = Archive()..addFile(ArchiveFile.string('hello.txt', 'hi'));

      final result = extractArchiveToDirectory(
        archive,
        tempDir,
        sanitize: true,
        log: testLog,
      );

      expect(result.extracted, 1);
      expect(result.skipped, 0);
      final extracted = File(p.join(tempDir.path, 'hello.txt'));
      expect(extracted.existsSync(), isTrue);
      expect(extracted.readAsStringSync(), 'hi');
    });

    test('creates nested directories for a file inside a sub-path', () {
      final archive = Archive()
        ..addFile(ArchiveFile.string('a/b/c.txt', 'deep'));

      final result = extractArchiveToDirectory(
        archive,
        tempDir,
        sanitize: true,
        log: testLog,
      );

      expect(result.extracted, 1);
      final extracted = File(p.join(tempDir.path, 'a', 'b', 'c.txt'));
      expect(extracted.existsSync(), isTrue);
      expect(extracted.readAsStringSync(), 'deep');
    });

    test('sanitises a filename containing Win32-reserved chars', () {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'shots/2025-09-12T16:04:38.049213.json',
            jsonEncode({'ok': true}),
          ),
        );

      final result = extractArchiveToDirectory(
        archive,
        tempDir,
        sanitize: true,
        log: testLog,
      );

      expect(result.extracted, 1);
      expect(result.skipped, 0);
      final sanitised = File(
        p.join(tempDir.path, 'shots', '2025-09-12T16_04_38.049213.json'),
      );
      expect(sanitised.existsSync(), isTrue);
      expect(jsonDecode(sanitised.readAsStringSync()), {'ok': true});
      // Original name must NOT exist — if it did, sanitisation is a no-op.
      expect(
        File(
          p.join(tempDir.path, 'shots', '2025-09-12T16:04:38.049213.json'),
        ).existsSync(),
        isFalse,
      );
    });

    test('still extracts remaining entries when one entry is pathological', () {
      final archive = Archive()
        ..addFile(ArchiveFile.string('good_before.txt', 'first'))
        ..addFile(ArchiveFile.string('shots/2025:bad.json', 'middle'))
        ..addFile(ArchiveFile.string('good_after.txt', 'last'));

      final result = extractArchiveToDirectory(
        archive,
        tempDir,
        sanitize: true,
        log: testLog,
      );

      // All three should land on disk; the middle one is sanitised, not
      // skipped.
      expect(result.extracted, 3);
      expect(result.skipped, 0);
      expect(
        File(p.join(tempDir.path, 'good_before.txt')).existsSync(),
        isTrue,
      );
      expect(File(p.join(tempDir.path, 'good_after.txt')).existsSync(), isTrue);
      expect(
        File(p.join(tempDir.path, 'shots', '2025_bad.json')).existsSync(),
        isTrue,
      );
    });

    test('handles an empty archive', () {
      final result = extractArchiveToDirectory(
        Archive(),
        tempDir,
        sanitize: true,
        log: testLog,
      );
      expect(result.extracted, 0);
      expect(result.skipped, 0);
    });

    test(
      'leaves entry names untouched when sanitize is false (POSIX hosts)',
      () {
        // On macOS/Linux, a filename containing `:` is valid — we want it
        // written as-is so skins that intentionally use such filenames keep
        // working. On Windows the OS would reject it; we gate sanitisation
        // at the caller with Platform.isWindows, so this test is only
        // meaningful on POSIX hosts.
        final archive = Archive()
          ..addFile(ArchiveFile.string('shots/2025-09-12T16:04:38.json', 'ok'));

        final result = extractArchiveToDirectory(
          archive,
          tempDir,
          sanitize: false,
          log: testLog,
        );

        expect(result.extracted, 1);
        expect(result.skipped, 0);
        final asWritten = File(
          p.join(tempDir.path, 'shots', '2025-09-12T16:04:38.json'),
        );
        expect(asWritten.existsSync(), isTrue);
        expect(asWritten.readAsStringSync(), 'ok');
      },
      testOn: '!windows',
    );
  });

  group('extractArchiveToDirectory rejects unsafe entry paths', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'reaprime_zip_unsafe_test_',
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    void expectArchiveRejected(Archive archive, String reason) {
      expect(
        () => extractArchiveToDirectory(archive, tempDir, sanitize: true),
        throwsFormatException,
        reason: reason,
      );
    }

    Archive archiveWith(String name) =>
        Archive()..addFile(ArchiveFile.string(name, 'boom'));

    test('rejects POSIX traversal components', () {
      for (final name in [
        '../escape.txt',
        'a/../../escape.txt',
        'a/../b.txt',
      ]) {
        expectArchiveRejected(archiveWith(name), 'entry "$name"');
      }
    });

    test('rejects Windows-style traversal with backslashes', () {
      for (final name in [
        r'..\escape.txt',
        r'a\..\escape.txt',
        r'..\..\etc\passwd',
      ]) {
        expectArchiveRejected(archiveWith(name), 'entry "$name"');
      }
    });

    test('rejects absolute POSIX paths', () {
      for (final name in ['/etc/passwd', '/tmp/escape.txt']) {
        expectArchiveRejected(archiveWith(name), 'entry "$name"');
      }
    });

    test('rejects Windows drive paths', () {
      for (final name in ['C:\\evil.txt', 'C:/evil.txt']) {
        expectArchiveRejected(archiveWith(name), 'entry "$name"');
      }
    });

    test('rejects UNC-style paths', () {
      for (final name in [
        r'\\server\share\evil.txt',
        '//server/share/evil.txt',
      ]) {
        expectArchiveRejected(archiveWith(name), 'entry "$name"');
      }
    });

    test('rejects NUL bytes in entry names', () {
      expectArchiveRejected(archiveWith('bad\x00name.txt'), 'NUL byte');
    });

    test('rejects the archive before writing anything', () {
      final sibling = File(
        p.join(tempDir.parent.path, 'escape_${p.basename(tempDir.path)}.txt'),
      );
      if (sibling.existsSync()) sibling.deleteSync();

      final archive = Archive()
        ..addFile(ArchiveFile.string('good.txt', 'fine'))
        ..addFile(ArchiveFile.string('../escape.txt', 'boom'));

      expectArchiveRejected(archive, 'traversal entry after a valid entry');

      // Pre-validation must reject the whole archive before any entry is
      // written — not even the innocent first entry may land.
      expect(
        tempDir.listSync(),
        isEmpty,
        reason: 'no entries may be written when the archive is rejected',
      );
      expect(
        sibling.existsSync(),
        isFalse,
        reason: 'nothing may land outside the extraction directory',
      );
      if (sibling.existsSync()) sibling.deleteSync();
    });

    test(
      'still extracts a sanitiseable entry (reserved chars are not unsafe)',
      () {
        final archive = Archive()
          ..addFile(ArchiveFile.string('shots/2025:bad.json', 'ok'));

        final result = extractArchiveToDirectory(
          archive,
          tempDir,
          sanitize: true,
        );

        expect(result.extracted, 1);
        expect(
          File(p.join(tempDir.path, 'shots', '2025_bad.json')).existsSync(),
          isTrue,
        );
      },
    );
  });

  group('installBundledSkinList', () {
    late Logger testLog;
    late List<LogRecord> logged;

    setUp(() {
      testLog = Logger.detached('InstallListTest');
      logged = <LogRecord>[];
      testLog.onRecord.listen(logged.add);
    });

    test('calls installOne for every skin id when all succeed', () async {
      final calls = <String>[];
      await installBundledSkinList(
        ['a', 'b', 'c'],
        (id) async => calls.add(id),
        log: testLog,
      );
      expect(calls, ['a', 'b', 'c']);
      expect(
        logged.where((r) => r.level >= Level.WARNING),
        isEmpty,
        reason: 'successful installs should not warn',
      );
    });

    test(
      'continues after a failure and still attempts later skins (issue #148)',
      () async {
        final calls = <String>[];
        await installBundledSkinList(['first', 'boom', 'third'], (id) async {
          calls.add(id);
          if (id == 'boom') throw StateError('simulated install failure');
        }, log: testLog);
        expect(calls, ['first', 'boom', 'third']);
        // The failure must be surfaced at warning level so users and logs
        // notice — the original bug hid it at fine.
        final warnings = logged.where((r) => r.level >= Level.WARNING).toList();
        expect(warnings, hasLength(1));
        expect(warnings.single.message, contains('boom'));
      },
    );

    test('attempts every skin when every install throws', () async {
      final calls = <String>[];
      await installBundledSkinList(['x', 'y', 'z'], (id) async {
        calls.add(id);
        throw StateError('always fails');
      }, log: testLog);
      expect(calls, ['x', 'y', 'z']);
      expect(logged.where((r) => r.level >= Level.WARNING).length, 3);
    });

    test('does nothing for an empty list', () async {
      final calls = <String>[];
      await installBundledSkinList(
        const [],
        (id) async => calls.add(id),
        log: testLog,
      );
      expect(calls, isEmpty);
    });
  });
}
