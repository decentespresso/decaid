import 'dart:io';
import 'package:reaprime/src/import/import_result.dart';

class De1appScanner {
  static Future<ScanResult> scan(String path) async {
    final historyV2 = await _basenames(Directory('$path/history_v2'), '.json');
    final history = await _basenames(Directory('$path/history'), '.shot');
    final shotCount = historyV2.union(history).length;
    final shotSource = _combinedSource(
      historyV2.isNotEmpty,
      history.isNotEmpty,
      'history_v2',
      'history',
    );

    final profilesV2 = await _basenames(
      Directory('$path/profiles_v2'),
      '.json',
    );
    final profiles = await _basenames(Directory('$path/profiles'), '.tcl');
    final profileCount = profilesV2.union(profiles).length;

    final hasDyeGrinders = await File(
      '$path/plugins/DYE/grinders.tdb',
    ).exists();

    final hasSettings = await File('$path/settings.tdb').exists();

    return ScanResult(
      shotCount: shotCount,
      profileCount: profileCount,
      hasDyeGrinders: hasDyeGrinders,
      hasSettings: hasSettings,
      sourcePath: path,
      shotSource: shotSource,
    );
  }

  /// Filenames (without extension) in [dir] ending in [extension], or an
  /// empty set if [dir] doesn't exist.
  static Future<Set<String>> _basenames(Directory dir, String extension) async {
    if (!await dir.exists()) return {};
    final names = <String>{};
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith(extension)) {
        final base = entity.uri.pathSegments.last;
        names.add(base.substring(0, base.length - extension.length));
      }
    }
    return names;
  }

  static String? _combinedSource(
    bool hasA,
    bool hasB,
    String sourceA,
    String sourceB,
  ) {
    if (hasA && hasB) return 'both';
    if (hasA) return sourceA;
    if (hasB) return sourceB;
    return null;
  }
}
