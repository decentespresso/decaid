import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';
import 'package:path/path.dart' as p;
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/services/export/archive_export.dart';
import 'package:reaprime/src/services/export/streaming_zip_writer.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';

class SupportPackageSources {
  final String driftFile;
  final String hiveDir;
  final String logDir;
  final String appVersion;

  const SupportPackageSources({
    required this.driftFile,
    required this.hiveDir,
    required this.logDir,
    required this.appVersion,
  });

  static Future<SupportPackageSources> resolve({
    required String appVersion,
  }) async {
    return SupportPackageSources(
      driftFile: await AppDirectories.driftFile,
      hiveDir: await AppDirectories.hive,
      logDir: await AppDirectories.logs,
      appVersion: appVersion,
    );
  }
}

Future<File> buildSupportPackage({
  required String outputPath,
  required String finalDestinationPath,
  required SupportPackageSources sources,
}) async {
  if (await FileSystemEntity.isDirectory(finalDestinationPath)) {
    throw StateError(
      'The recovery package destination is a directory: $finalDestinationPath',
    );
  }
  final destinationDirectory = await _canonicalDirectory(
    p.dirname(p.normalize(p.absolute(finalDestinationPath))),
  );
  final driftDirectory = await _canonicalDirectory(
    p.dirname(p.absolute(sources.driftFile)),
  );
  final hiveDirectory = await _canonicalDirectory(sources.hiveDir);
  final logDirectory = await _canonicalDirectory(sources.logDir);
  final insideSourceDirectory =
      p.equals(driftDirectory, destinationDirectory) ||
      p.equals(logDirectory, destinationDirectory) ||
      p.equals(hiveDirectory, destinationDirectory) ||
      p.isWithin(hiveDirectory, destinationDirectory);
  if (insideSourceDirectory) {
    throw StateError(
      'The recovery package cannot be written into a data directory: '
      '$finalDestinationPath',
    );
  }

  final hiveFiles = <File>[];
  final hive = Directory(sources.hiveDir);
  if (await hive.exists()) {
    final listed = await hive
        .list(recursive: true, followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    listed.sort((a, b) => a.path.compareTo(b.path));
    hiveFiles.addAll(listed);
  }

  StreamingZipWriter? writer;
  final entries = <String>[];
  try {
    writer = await StreamingZipWriter.create(destination: File(outputPath));

    Future<void> addFile(File file, String name) async {
      await writer!.writeFile(file, name);
      entries.add(name);
    }

    final drift = File(sources.driftFile);
    if (await drift.exists()) {
      await addFile(drift, 'streamline_bridge.sqlite');
    }
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final sidecar = File('${sources.driftFile}$suffix');
      if (await sidecar.exists()) {
        await addFile(sidecar, 'streamline_bridge.sqlite$suffix');
      }
    }

    for (final file in hiveFiles) {
      final relative = p.relative(file.path, from: sources.hiveDir);
      final name = _safeEntryName('store/${relative.replaceAll(r'\', '/')}');
      await addFile(file, name);
    }

    for (final name in const ['log.txt', 'webview_console.log']) {
      final file = File(p.join(sources.logDir, name));
      if (await file.exists()) await addFile(file, name);
    }

    entries.add('manifest.txt');
    final manifest = [
      'appVersion: ${sources.appVersion}',
      'operatingSystem: ${Platform.operatingSystem}',
      'createdAt: ${DateTime.now().toUtc().toIso8601String()}',
      'entries:',
      ...entries.map((entry) => '- $entry'),
      '',
    ].join('\n');
    final manifestEntry = writer.addEntry('manifest.txt');
    manifestEntry.write(Uint8List.fromList(utf8.encode(manifest)));
    manifestEntry.close();
    await writer.close();
    return writer.file;
  } catch (_) {
    if (writer != null) await writer.abort();
    rethrow;
  }
}

Future<String> _canonicalDirectory(String path) async {
  final absolute = p.normalize(p.absolute(path));
  try {
    return await Directory(absolute).resolveSymbolicLinks();
  } on FileSystemException {
    return absolute;
  }
}

String _safeEntryName(String name) {
  if (name.startsWith('/') ||
      name.contains('\\') ||
      name.split('/').contains('..')) {
    throw StateError('Invalid support package entry name: $name');
  }
  return name;
}

Future<File> writeSupportPackage({
  required ArchiveTarget target,
  required SupportPackageSources sources,
}) {
  return buildSupportPackage(
    outputPath: target.outputPath,
    finalDestinationPath: target.finalPath,
    sources: sources,
  );
}

Future<DeliveryOutcome> saveSupportPackage({
  required Rect sharePositionOrigin,
}) async {
  final sources = await SupportPackageSources.resolve(
    appVersion: BuildInfo.version,
  );
  final timestamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .split('.')
      .first;
  return deliverArchive(
    fileName: 'decent-recovery-$timestamp.zip',
    sharePositionOrigin: sharePositionOrigin,
    dialogTitle: 'Choose where to save the recovery package',
    writeArchive: (target) async {
      await Isolate.run(
        () => writeSupportPackage(target: target, sources: sources),
      );
    },
  );
}
