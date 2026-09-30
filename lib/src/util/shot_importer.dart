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
      _validateDecaidShotExportShape(item);
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

    _validateDecaidShotExportShape(json);
    final shot = ShotRecord.fromRecordedJson(json);
    await storage.storeShot(shot);
  }

  void _validateDecaidShotExportShape(Map<String, dynamic> json) {
    final missingFields = <String>[
      if (json['id'] is! String) 'id',
      if (json['timestamp'] is! String) 'timestamp',
      if (json['measurements'] is! List) 'measurements',
      if (json['workflow'] is! Map) 'workflow',
    ];
    if (missingFields.isEmpty) return;

    final isDe1AppHistoryV2Shot = json['clock'] != null;
    final hint = isDe1AppHistoryV2Shot
        ? ' This looks like a De1App history_v2 shot — use "Import from De1App" instead.'
        : '';
    throw FormatException(
      'Not a Decaid shot export (missing or invalid: ${missingFields.join(', ')}).$hint',
    );
  }
}
