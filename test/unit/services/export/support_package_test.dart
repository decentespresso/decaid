import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/export/support_package.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('support-package-test-');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('writes the expected support package entries', () async {
    final drift = File('${temp.path}/streamline_bridge.sqlite')
      ..writeAsBytesSync([1, 2, 3]);
    File('${drift.path}-journal').writeAsBytesSync([7, 8]);
    final hive = Directory('${temp.path}/store/a/b')
      ..createSync(recursive: true);
    File('${hive.path}/one.bin').writeAsBytesSync([4, 5]);
    File('${temp.path}/store/two.bin').writeAsBytesSync([6]);
    File('${temp.path}/log.txt').writeAsStringSync('log');
    final out = Directory('${temp.path}/out')..createSync();
    final destination = '${out.path}/package.zip';

    await buildSupportPackage(
      outputPath: destination,
      finalDestinationPath: destination,
      sources: SupportPackageSources(
        driftFile: drift.path,
        hiveDir: '${temp.path}/store',
        logDir: temp.path,
        appVersion: '1.2.3',
      ),
    );

    final archive = ZipDecoder().decodeBytes(
      File(destination).readAsBytesSync(),
    );
    expect(archive.files.map((file) => file.name).toSet(), {
      'streamline_bridge.sqlite',
      'streamline_bridge.sqlite-journal',
      'store/a/b/one.bin',
      'store/two.bin',
      'log.txt',
      'manifest.txt',
    });
    expect(archive.findFile('streamline_bridge.sqlite')!.content, [1, 2, 3]);
    expect(archive.files.any((file) => file.name.contains(r'\')), isFalse);
    final manifest = utf8.decode(
      archive.findFile('manifest.txt')!.content as List<int>,
    );
    expect(manifest, contains('appVersion: 1.2.3'));
    expect(manifest, contains('- manifest.txt'));
  });

  test('does not recursively walk the mobile log directory', () async {
    final out = Directory('${temp.path}/out')..createSync();
    final support = Directory('${temp.path}/support')..createSync();
    File('${support.path}/streamline_bridge.sqlite').writeAsBytesSync([1]);
    Directory('${support.path}/store').createSync();
    File('${support.path}/store/value').writeAsBytesSync([2]);
    File('${support.path}/unrelated.txt').writeAsBytesSync([3]);
    File('${support.path}/logs/nested.txt')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([4]);
    final destination = '${out.path}/package.zip';

    await buildSupportPackage(
      outputPath: destination,
      finalDestinationPath: destination,
      sources: SupportPackageSources(
        driftFile: '${support.path}/streamline_bridge.sqlite',
        hiveDir: '${support.path}/store',
        logDir: support.path,
        appVersion: '1.2.3',
      ),
    );

    final names = ZipDecoder()
        .decodeBytes(File(destination).readAsBytesSync())
        .files
        .map((file) => file.name)
        .toList();
    expect(names.toSet(), {
      'streamline_bridge.sqlite',
      'store/value',
      'manifest.txt',
    });
    expect(names.length, names.toSet().length);
  });

  test('skips missing optional files', () async {
    final drift = File('${temp.path}/streamline_bridge.sqlite')
      ..writeAsBytesSync([1]);
    final out = Directory('${temp.path}/out')..createSync();
    final destination = '${out.path}/package.zip';

    await buildSupportPackage(
      outputPath: destination,
      finalDestinationPath: destination,
      sources: SupportPackageSources(
        driftFile: drift.path,
        hiveDir: '${temp.path}/store',
        logDir: temp.path,
        appVersion: '1.2.3',
      ),
    );

    final names = ZipDecoder()
        .decodeBytes(File(destination).readAsBytesSync())
        .files
        .map((file) => file.name)
        .toSet();
    expect(names, containsAll({'streamline_bridge.sqlite', 'manifest.txt'}));
    expect(names, isNot(contains('streamline_bridge.sqlite-wal')));
    expect(names, isNot(contains('streamline_bridge.sqlite-shm')));
    expect(names, isNot(contains('streamline_bridge.sqlite-journal')));
    expect(names, isNot(contains('webview_console.log')));
  });

  test('rejects a destination that aliases a source file', () async {
    final drift = File('${temp.path}/streamline_bridge.sqlite')
      ..writeAsBytesSync([1]);

    await expectLater(
      buildSupportPackage(
        outputPath: drift.path,
        finalDestinationPath: drift.path,
        sources: SupportPackageSources(
          driftFile: drift.path,
          hiveDir: '${temp.path}/store',
          logDir: temp.path,
          appVersion: '1.2.3',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await drift.readAsBytes(), [1]);
  });

  test('rejects a destination in a nested hive subdirectory', () async {
    final hive = Directory('${temp.path}/store/nested')
      ..createSync(recursive: true);
    final source = File('${hive.path}/settings.hive')..writeAsBytesSync([2]);
    final destination = source.path;

    await expectLater(
      buildSupportPackage(
        outputPath: '$destination.part',
        finalDestinationPath: destination,
        sources: SupportPackageSources(
          driftFile: '${temp.path}/missing.sqlite',
          hiveDir: '${temp.path}/store',
          logDir: '${temp.path}/logs',
          appVersion: '1.2.3',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await source.readAsBytes(), [2]);
  });

  test('rejects a destination that is a directory', () async {
    final target = Directory('${temp.path}/out')..createSync();

    await expectLater(
      buildSupportPackage(
        outputPath: '${target.path}.part',
        finalDestinationPath: target.path,
        sources: SupportPackageSources(
          driftFile: '${temp.path}/missing.sqlite',
          hiveDir: '${temp.path}/store',
          logDir: '${temp.path}/logs',
          appVersion: '1.2.3',
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects a destination inside the hive directory', () async {
    final hive = Directory('${temp.path}/store')..createSync();
    final source = File('${hive.path}/settings.hive')..writeAsBytesSync([2]);
    final destination = '${hive.path}/package.zip';

    await expectLater(
      buildSupportPackage(
        outputPath: destination,
        finalDestinationPath: destination,
        sources: SupportPackageSources(
          driftFile: '${temp.path}/missing.sqlite',
          hiveDir: hive.path,
          logDir: temp.path,
          appVersion: '1.2.3',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await source.readAsBytes(), [2]);
  });

  test(
    'rejects a destination that reaches a source directory by symlink',
    () async {
      final support = Directory('${temp.path}/support')..createSync();
      final drift = File('${support.path}/streamline_bridge.sqlite')
        ..writeAsBytesSync([1]);
      final shortcut = Link('${temp.path}/shortcut');
      await shortcut.create(support.path);

      await expectLater(
        buildSupportPackage(
          outputPath: '${shortcut.path}/package.zip',
          finalDestinationPath: '${shortcut.path}/package.zip',
          sources: SupportPackageSources(
            driftFile: drift.path,
            hiveDir: '${support.path}/store',
            logDir: support.path,
            appVersion: '1.2.3',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await drift.readAsBytes(), [1]);
    },
  );

  test('a partial output path cannot smuggle a source destination', () async {
    final drift = File('${temp.path}/streamline_bridge.sqlite')
      ..writeAsBytesSync([1, 2, 3]);

    await expectLater(
      writeSupportPackage(
        target: (outputPath: '${drift.path}.part', finalPath: drift.path),
        sources: SupportPackageSources(
          driftFile: drift.path,
          hiveDir: '${temp.path}/store',
          logDir: temp.path,
          appVersion: '1.2.3',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await drift.readAsBytes(), [1, 2, 3]);
  });
}
