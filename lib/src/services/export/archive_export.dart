import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:reaprime/src/util/temp_archive_files.dart';
import 'package:share_plus/share_plus.dart';

Uint8List zipFiles(Map<String, Uint8List> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<bool> saveArchiveBytes({
  required String fileName,
  required Uint8List bytes,
  String? dialogTitle,
}) async {
  final path = await FilePicker.saveFile(
    fileName: fileName,
    dialogTitle: dialogTitle,
    bytes: bytes,
  );
  return path != null;
}

enum DeliveryOutcome { saved, cancelled }

typedef ArchiveTarget = ({String outputPath, String finalPath});

Future<void> writeArchiveToDestination({
  required String destinationPath,
  required Future<void> Function(ArchiveTarget target) writeArchive,
}) async {
  final staging = await TempArchiveDir.create('reaprime-export-');
  try {
    final staged = File(staging.filePath('archive'));
    await writeArchive((outputPath: staged.path, finalPath: destinationPath));
    if (FileSystemEntity.typeSync(destinationPath, followLinks: false) ==
        FileSystemEntityType.link) {
      await Link(destinationPath).delete();
    }
    await staged.copy(destinationPath);
  } finally {
    await staging.dispose();
  }
}

Future<DeliveryOutcome> deliverArchive({
  required String fileName,
  required Future<void> Function(ArchiveTarget target) writeArchive,
  String? dialogTitle,
  required Rect Function() sharePositionOrigin,
}) async {
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android) {
    final tempDir = await TempArchiveDir.create('reaprime-native-export-');
    final file = File(tempDir.filePath(fileName));
    try {
      await writeArchive((outputPath: file.path, finalPath: file.path));
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/zip')],
          subject: 'Decent backup',
          sharePositionOrigin: sharePositionOrigin(),
        ),
      );
      if (result.status == ShareResultStatus.dismissed) {
        await tempDir.dispose();
        return DeliveryOutcome.cancelled;
      }
      Timer(const Duration(minutes: 5), tempDir.dispose);
      return DeliveryOutcome.saved;
    } catch (_) {
      await tempDir.dispose();
      rethrow;
    }
  }

  final path = await FilePicker.saveFile(
    fileName: fileName,
    dialogTitle: dialogTitle,
  );
  if (path == null) return DeliveryOutcome.cancelled;
  await writeArchiveToDestination(
    destinationPath: path,
    writeArchive: writeArchive,
  );
  return DeliveryOutcome.saved;
}
