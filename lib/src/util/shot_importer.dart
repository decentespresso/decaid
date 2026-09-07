import 'dart:convert';

import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';

class ShotImporter {
  final StorageService storage;

  ShotImporter({required this.storage});

  Future<int> importShotsJson(String data) async {
    final decoded = jsonDecode(data);

    if (decoded is! List) {
      throw FormatException('Expected JSON array, got ${decoded.runtimeType}');
    }

    int count = 0;
    for (var item in decoded) {
      if (item is! Map<String, dynamic>) {
        throw FormatException(
          'Expected JSON object in array, got ${item.runtimeType}',
        );
      }
      final shot = ShotRecord.fromRecordedJson(item);
      await storage.storeShot(shot);
      count++;
    }

    return count;
  }

  Future<void> importShotJson(String data) async {
    final json = jsonDecode(data);

    if (json is! Map<String, dynamic>) {
      throw FormatException('Expected JSON object, got ${json.runtimeType}');
    }

    final shot = ShotRecord.fromRecordedJson(json);
    await storage.storeShot(shot);
  }
}
