import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

final _log = Logger('SafFolderCopier');

/// Copies relevant de1app subdirectories from an Android SAF-picked folder
/// to local cache so that [De1appScanner] and [De1appImporter] can access
/// them with normal dart:io operations.
class SafFolderCopier {
  /// The subdirectories (and files) we care about from the de1app folder.
  static const _relevantDirs = ['history_v2', 'history', 'profiles_v2'];
  static const _stagingDirName = 'de1app_import_staging';

  /// Opens the SAF folder picker and copies relevant contents to app cache.
  ///
  /// Returns the local staging directory path, or `null` if the user cancelled.
  /// Opens the SAF folder picker, copies relevant contents to app cache.
  /// Combines [pickDirectory] and [copyFromUri] in one call.
  ///
  /// Returns the local staging directory path, or `null` if the user cancelled.
  Future<String?> pickAndCopy({
    void Function(int copied, int total)? onProgress,
  }) async {
    final uri = await pickDirectory();
    if (uri == null) return null;
    return copyFromUri(uri, onProgress: onProgress);
  }

  /// Opens the SAF folder picker and returns the tree URI, or `null` if
  /// the user cancelled. Use with [copyFromUri] for two-step pick+copy.
  Future<String?> pickDirectory() async {
    final picked = await SafUtil().pickDirectory(
      writePermission: false,
      persistablePermission: false,
    );
    if (picked == null) {
      _log.info('User cancelled directory picker');
      return null;
    }
    _log.info('Picked directory: ${picked.name} (${picked.uri})');
    return picked.uri;
  }

  /// Copies relevant de1app subdirectories from a SAF tree URI to app cache.
  ///
  /// Returns the local staging directory path, or `null` if no relevant
  /// files were found.
  Future<String?> copyFromUri(
    String treeUri, {
    void Function(int copied, int total)? onProgress,
  }) async {
    final stagingPath = await _stagingPath();
    final stagingDir = Directory(stagingPath);
    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
    await stagingDir.create(recursive: true);

    final topLevel = await SafUtil().list(treeUri);

    final filesToCopy = <_CopyTask>[];

    for (final entry in topLevel) {
      if (entry.isDir && _relevantDirs.contains(entry.name)) {
        final subFiles = await SafUtil().list(entry.uri);
        final destDir = '$stagingPath/${entry.name}';
        await Directory(destDir).create(recursive: true);

        for (final file in subFiles) {
          if (!file.isDir) {
            filesToCopy.add(
              _CopyTask(sourceUri: file.uri, destPath: '$destDir/${file.name}'),
            );
          }
        }
      }
    }

    await _collectGrinderFile(topLevel, stagingPath, filesToCopy);

    final settingsFile = topLevel
        .where((e) => !e.isDir && e.name == 'settings.tdb')
        .firstOrNull;
    if (settingsFile != null) {
      filesToCopy.add(
        _CopyTask(
          sourceUri: settingsFile.uri,
          destPath: '$stagingPath/settings.tdb',
        ),
      );
    }

    _log.info('Found ${filesToCopy.length} files to copy');

    if (filesToCopy.isEmpty) {
      await cleanup();
      return null;
    }

    final safStream = SafStream();
    var copied = 0;
    for (final task in filesToCopy) {
      await safStream.copyToLocalFile(task.sourceUri, task.destPath);
      copied++;
      onProgress?.call(copied, filesToCopy.length);
    }

    _log.info('Copied $copied files to staging directory');
    return stagingPath;
  }

  /// Deletes the staging directory if it exists.
  Future<void> cleanup() async {
    final path = await _stagingPath();
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      _log.info('Cleaned up staging directory');
    }
  }

  Future<String> _stagingPath() async {
    final tempDir = await getTemporaryDirectory();
    return '${tempDir.path}/$_stagingDirName';
  }

  /// Locates plugins/DYE/grinders.tdb in the SAF tree and adds it to
  /// [filesToCopy] if found.
  Future<void> _collectGrinderFile(
    List<SafDocumentFile> topLevel,
    String stagingPath,
    List<_CopyTask> filesToCopy,
  ) async {
    try {
      final pluginsEntry = topLevel
          .where((e) => e.isDir && e.name == 'plugins')
          .firstOrNull;
      if (pluginsEntry == null) return;

      final pluginsContents = await SafUtil().list(pluginsEntry.uri);
      final dyeEntry = pluginsContents
          .where((e) => e.isDir && e.name == 'DYE')
          .firstOrNull;
      if (dyeEntry == null) return;

      final dyeContents = await SafUtil().list(dyeEntry.uri);
      final grindersFile = dyeContents
          .where((e) => !e.isDir && e.name == 'grinders.tdb')
          .firstOrNull;
      if (grindersFile == null) return;

      final destDir = '$stagingPath/plugins/DYE';
      await Directory(destDir).create(recursive: true);
      filesToCopy.add(
        _CopyTask(
          sourceUri: grindersFile.uri,
          destPath: '$destDir/grinders.tdb',
        ),
      );
    } catch (e) {
      _log.warning('Could not locate grinders.tdb: $e');
    }
  }
}

class _CopyTask {
  final String sourceUri;
  final String destPath;

  _CopyTask({required this.sourceUri, required this.destPath});
}
