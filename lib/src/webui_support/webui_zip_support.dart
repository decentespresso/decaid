import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _win32ReservedChars = RegExp(r'[<>:"|?*]');

String sanitizeZipEntryPath(String entryName) {
  if (entryName.isEmpty) return entryName;
  final segments = entryName.split('/');
  final sanitised = segments
      .map((segment) {
        var s = segment.replaceAll(_win32ReservedChars, '_');
        while (s.isNotEmpty && (s.endsWith('.') || s.endsWith(' '))) {
          s = s.substring(0, s.length - 1);
        }
        return s;
      })
      .join('/');
  return sanitised;
}

class ExtractionResult {
  final int extracted;

  final int skipped;

  const ExtractionResult({required this.extracted, required this.skipped});
}

bool isSafeZipEntryPath(String entryName) {
  if (entryName.contains('\x00')) return false;
  if (entryName.startsWith('/') || entryName.startsWith('\\')) return false;
  if (entryName.startsWith('\\\\') || entryName.startsWith('//')) return false;

  if (entryName.length >= 2 && entryName.codeUnitAt(1) == 0x3A) {
    final first = entryName.codeUnitAt(0);
    final isLetter =
        (first >= 0x41 && first <= 0x5A) || (first >= 0x61 && first <= 0x7A);
    if (isLetter) return false;
  }

  final normalized = entryName.replaceAll('\\', '/');
  for (final segment in normalized.split('/')) {
    if (segment == '..') return false;
  }
  return true;
}

ExtractionResult extractArchiveToDirectory(
  Archive archive,
  Directory destDir, {
  required bool sanitize,
  Logger? log,
}) {
  for (final entry in archive) {
    final originalName = entry.name;
    final safeName = sanitize
        ? sanitizeZipEntryPath(originalName)
        : originalName;
    final outPath = p.normalize(p.join(destDir.path, safeName));
    if (!isSafeZipEntryPath(originalName) ||
        (outPath != destDir.path && !p.isWithin(destDir.path, outPath))) {
      throw FormatException(
        'Rejecting zip archive: entry "$originalName" resolves outside the '
        'extraction directory',
      );
    }
  }

  var extracted = 0;
  var skipped = 0;

  for (final entry in archive) {
    final originalName = entry.name;
    final safeName = sanitize
        ? sanitizeZipEntryPath(originalName)
        : originalName;

    if (safeName != originalName) {
      log?.fine('Sanitised zip entry name: "$originalName" -> "$safeName"');
    }

    if (safeName.isEmpty) {
      skipped += entry.isFile ? 1 : 0;
      log?.warning(
        'Skipping zip entry with empty path after sanitisation: '
        '"$originalName"',
      );
      continue;
    }

    final outPath = p.join(destDir.path, safeName);

    try {
      if (entry.isFile) {
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(entry.content as List<int>);
        extracted++;
      } else {
        Directory(outPath).createSync(recursive: true);
      }
    } catch (e, st) {
      skipped += entry.isFile ? 1 : 0;
      log?.warning(
        'Failed to extract zip entry "$originalName" '
        '(sanitised to "$safeName"); skipping',
        e,
        st,
      );
    }
  }

  return ExtractionResult(extracted: extracted, skipped: skipped);
}

Future<void> installBundledSkinList(
  List<String> skinIds,
  Future<void> Function(String skinId) installOne, {
  Logger? log,
}) async {
  for (final skinId in skinIds) {
    try {
      await installOne(skinId);
    } catch (e, st) {
      log?.warning('Failed to install bundled skin "$skinId"', e, st);
    }
  }
}
