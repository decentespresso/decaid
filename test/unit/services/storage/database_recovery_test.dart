import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/storage/database_recovery.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('database-recovery-test-');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('renames and deletes database targets', () async {
    final drift = File('${temp.path}/streamline_bridge.sqlite')..createSync();
    File('${drift.path}-wal').writeAsStringSync('wal');
    File('${drift.path}-shm').writeAsStringSync('shm');
    File('${drift.path}-journal').writeAsStringSync('journal');
    final hive = Directory('${temp.path}/store')..createSync();
    File('${hive.path}/value').writeAsStringSync('value');

    final report = await DatabaseReset(
      driftFile: drift.path,
      hiveDir: hive.path,
    ).run();

    expect(
      report.moved,
      containsAll([
        drift.path,
        '${drift.path}-wal',
        '${drift.path}-shm',
        '${drift.path}-journal',
        hive.path,
      ]),
    );
    expect(report.renameFailures, isEmpty);
    expect(report.leftovers, isEmpty);
    expect(report.isClean, isTrue);
    expect(await drift.exists(), isFalse);
    expect(await File('${drift.path}-wal').exists(), isFalse);
    expect(await File('${drift.path}-shm').exists(), isFalse);
    expect(await File('${drift.path}-journal').exists(), isFalse);
    expect(await hive.exists(), isFalse);
    expect(
      temp.listSync().where((entry) => entry.path.contains('.reset-')),
      isEmpty,
    );
  });

  test('reports leftovers when quarantined data cannot be deleted', () async {
    final directory = Directory('${temp.path}/q')..createSync();
    final quarantined = File(
      '${directory.path}/streamline_bridge.sqlite.reset-1',
    )..writeAsBytesSync([9]);
    await Process.run('chmod', ['500', directory.path]);
    addTearDown(() => Process.run('chmod', ['700', directory.path]));

    final report = await DatabaseReset(
      driftFile: '${directory.path}/streamline_bridge.sqlite',
      hiveDir: null,
    ).run();

    expect(report.isClean, isFalse);
    expect(report.leftovers, contains(quarantined.path));
  }, skip: Platform.isWindows);

  test('a retry reclaims quarantine left by a previous run', () async {
    final drift = File('${temp.path}/streamline_bridge.sqlite');
    final quarantined = File('${drift.path}.reset-1')..writeAsBytesSync([9]);

    final report = await DatabaseReset(
      driftFile: drift.path,
      hiveDir: null,
    ).run();

    final remaining = temp.listSync().where(
      (entry) => entry.path.contains('.reset-'),
    );
    expect(remaining.isEmpty || !report.isClean, isTrue);
    expect(await quarantined.exists(), isFalse);
  });

  test('partial reports are not clean', () {
    expect(const ResetReport(renameFailures: ['/db']).isClean, isFalse);
    expect(const ResetReport(leftovers: ['/db.reset-1']).isClean, isFalse);
  });

  test('skips missing targets and leaves unrelated directories', () async {
    final drift = File('${temp.path}/streamline_bridge.sqlite')..createSync();
    final logs = Directory('${temp.path}/logs')..createSync();
    final plugins = Directory('${temp.path}/plugins')..createSync();
    File('${logs.path}/log.txt').writeAsStringSync('log');
    File('${plugins.path}/plugin').writeAsStringSync('plugin');

    final report = await DatabaseReset(
      driftFile: drift.path,
      hiveDir: '${temp.path}/missing-store',
    ).run();

    expect(report.isClean, isTrue);
    expect(await logs.exists(), isTrue);
    expect(await plugins.exists(), isTrue);
    expect(await File('${logs.path}/log.txt').readAsString(), 'log');
    expect(await File('${plugins.path}/plugin').readAsString(), 'plugin');
  });
}
