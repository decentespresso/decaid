import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reaprime/src/services/storage/app_directories.dart';

class ResetReport {
  final List<String> moved;
  final List<String> renameFailures;
  final List<String> leftovers;

  const ResetReport({
    this.moved = const [],
    this.renameFailures = const [],
    this.leftovers = const [],
  });

  bool get isClean => renameFailures.isEmpty && leftovers.isEmpty;
}

class DatabaseReset {
  DatabaseReset({required this._driftFile, required this._hiveDir});

  static const String quarantineSuffix = '.reset-';

  final String _driftFile;
  final String? _hiveDir;

  static Future<DatabaseReset> fromAppDirectories() async {
    return DatabaseReset(
      driftFile: await AppDirectories.driftFile,
      hiveDir: await AppDirectories.hive,
    );
  }

  Future<ResetReport> run() async {
    final targets = <String>[
      _driftFile,
      '$_driftFile-wal',
      '$_driftFile-shm',
      '$_driftFile-journal',
    ];
    final hiveDir = _hiveDir;
    if (hiveDir != null) targets.add(hiveDir);
    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
    final moved = <String>[];
    final renameFailures = <String>[];
    final leftovers = <String>[];
    final renamed = <({String original, String reset})>[];

    for (final target in targets) {
      await _reclaimQuarantine(target, leftovers);
      final entity = FileSystemEntity.typeSync(target, followLinks: false);
      if (entity == FileSystemEntityType.notFound) continue;
      final resetPath = '$target$quarantineSuffix$timestamp';
      try {
        if (entity == FileSystemEntityType.directory) {
          await Directory(target).rename(resetPath);
        } else {
          await File(target).rename(resetPath);
        }
        renamed.add((original: target, reset: resetPath));
      } catch (_) {
        renameFailures.add(target);
      }
    }

    for (final item in renamed) {
      if (await _deletePath(item.reset)) {
        moved.add(item.original);
      } else {
        leftovers.add(item.reset);
      }
    }

    return ResetReport(
      moved: List.unmodifiable(moved),
      renameFailures: List.unmodifiable(renameFailures),
      leftovers: List.unmodifiable(leftovers),
    );
  }

  Future<void> _reclaimQuarantine(String target, List<String> leftovers) async {
    final directory = Directory(p.dirname(target));
    if (!await directory.exists()) return;
    final prefix = '${p.basename(target)}$quarantineSuffix';
    await for (final entry in directory.list(followLinks: false)) {
      if (!p.basename(entry.path).startsWith(prefix)) continue;
      if (!await _deletePath(entry.path)) leftovers.add(entry.path);
    }
  }

  Future<bool> _deletePath(String path) async {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
