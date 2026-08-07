import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Pure helpers backing [WebUIStorage] zip handling.
///
/// Extracted from `webui_storage.dart` so the bug-prone bits (Win32 filename
/// handling, per-iteration error isolation) can be unit-tested without
/// standing up the full storage + asset bundle stack.
///
/// Issues this file addresses:
///   - https://github.com/decentespresso/decaid/issues/147
///     `_installFromZip` crashed on Windows-reserved filename chars.
///   - https://github.com/decentespresso/decaid/issues/148
///     `_copyBundledSkins` silently skipped every later bundled skin if any
///     earlier one threw.

/// Characters Win32 forbids in path components: `<>:"|?*`.
final _win32ReservedChars = RegExp(r'[<>:"|?*]');

/// Sanitises a single zip entry path so it is safe to write on every host
/// OS — most importantly Windows, which rejects the chars in
/// [_win32ReservedChars] and silently strips trailing dots / spaces from path
/// segments.
///
/// Forward-slash separators are preserved; each segment between separators is
/// sanitised independently. The function is intentionally lossless about
/// non-reserved bytes (including non-ASCII), so localised filenames survive
/// untouched.
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

/// Result of extracting an [Archive] to disk.
class ExtractionResult {
  /// Number of file entries written successfully.
  final int extracted;

  /// Number of file entries that failed to write and were skipped.
  final int skipped;

  const ExtractionResult({required this.extracted, required this.skipped});
}

/// Returns true when [entryName] is safe to write under a destination
/// directory. Archive entry names are untrusted input, so this rejects
/// anything that could resolve outside the extraction root:
///
///   - NUL bytes
///   - absolute paths (leading `/` or `\`, Windows drive prefixes, UNC)
///   - `..` path components, using `/` or `\` separators (so Windows-style
///     traversal like `..\escape` is caught on every host)
///
/// Win32-reserved characters (`<>:"|?*`) are NOT rejected here — they are
/// handled by [sanitizeZipEntryPath] so otherwise-valid POSIX filenames
/// survive on non-Windows hosts.
bool isSafeZipEntryPath(String entryName) {
  if (entryName.contains('\x00')) return false;
  if (entryName.startsWith('/') || entryName.startsWith('\\')) return false;
  if (entryName.startsWith('\\\\') || entryName.startsWith('//')) return false;

  if (entryName.length >= 2 && entryName.codeUnitAt(1) == 0x3A /* : */ ) {
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

/// Extracts every entry of [archive] under [destDir], isolating per-entry
/// failures so a single bad entry cannot abort the whole extraction.
///
/// Archive entry names are treated as untrusted. Every entry is validated
/// against path-traversal before anything is written: if any entry is
/// absolute, contains `..` components, or would resolve outside [destDir],
/// the whole archive is rejected with a [FormatException] and nothing is
/// written — traversal is never silently sanitised away.
///
/// When [sanitize] is true, each entry path is run through
/// [sanitizeZipEntryPath] first — callers set this on Windows, where the
/// raw filename would otherwise be rejected by the OS. On macOS and Linux
/// filenames like `2025:bad.json` are valid and we leave them alone, so
/// skins that legitimately use them keep working.
///
/// Each failed entry is logged at [Level.WARNING] (when [log] is supplied)
/// and counted in [ExtractionResult.skipped]. Successful entries are counted
/// in [ExtractionResult.extracted]. Directory entries are created but not
/// counted in either total — only file writes affect the counters.
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

/// Iterates [skinIds], calling [installOne] for each one in order. Each
/// iteration is isolated: if [installOne] throws, the failure is logged at
/// [Level.WARNING] (when [log] is supplied) and the loop continues with the
/// next id.
///
/// This is the primary fix for issue #148: the previous loop wrapped the
/// whole iteration in one `try/catch` and broke out on the first failure,
/// silently dropping every later skin.
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
