import 'dart:io';
import 'package:reaprime/src/import/import_result.dart';

class De1appScanner {
  static Future<ScanResult> scan(String path) async {
    int shotCount = 0;
    String? shotSource;
    int profileCount = 0;
    bool hasDyeGrinders = false;

    final historyV2 = Directory('$path/history_v2');
    if (await historyV2.exists()) {
      shotCount = await _countFiles(historyV2, '.json');
      if (shotCount > 0) shotSource = 'history_v2';
    }
    if (shotCount == 0) {
      final history = Directory('$path/history');
      if (await history.exists()) {
        shotCount = await _countFiles(history, '.shot');
        if (shotCount > 0) shotSource = 'history';
      }
    }

    final profilesV2 = Directory('$path/profiles_v2');
    if (await profilesV2.exists()) {
      profileCount = await _countFiles(profilesV2, '.json');
    }

    hasDyeGrinders = await File('$path/plugins/DYE/grinders.tdb').exists();

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

  static Future<int> _countFiles(Directory dir, String extension) async {
    var count = 0;
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith(extension)) count++;
    }
    return count;
  }
}
