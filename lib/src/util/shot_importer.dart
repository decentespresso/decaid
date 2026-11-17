import 'dart:convert';

import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';

class ShotImporter {
  final PersistenceController controller;

  ShotImporter({required this.controller});

  Future<int> importJson(String data) async {
    final decoded = _decodeJson(data);
    return _importShots(decoded is List ? decoded : [decoded]);
  }

  Future<int> importShotsJson(String data) async {
    final decoded = _decodeJson(data);

    if (decoded is! List) {
      throw UserFacingFormatException(
        'Expected JSON array, got ${decoded.runtimeType}',
      );
    }

    return _importShots(decoded);
  }

  Future<int> _importShots(List<dynamic> decoded) async {
    int count = 0;
    try {
      for (var item in decoded) {
        if (item is! Map<String, dynamic>) {
          throw UserFacingFormatException(
            'Expected JSON object in array, got ${item.runtimeType}',
          );
        }
        final shot = _shotFromJson(item);
        await controller.storeShot(shot, notifyApplication: false);
        count++;
      }
    } finally {
      if (count > 0) controller.notifyShotsChanged();
    }

    return count;
  }

  Future<void> importShotJson(String data) async {
    final json = _decodeJson(data);

    if (json is! Map<String, dynamic>) {
      throw UserFacingFormatException(
        'Expected JSON object, got ${json.runtimeType}',
      );
    }

    await _importShots([json]);
  }

  Object? _decodeJson(String data) {
    try {
      return jsonDecode(data);
    } on FormatException catch (error, stack) {
      Error.throwWithStackTrace(
        UserFacingFormatException(error.message),
        stack,
      );
    }
  }

  ShotRecord _shotFromJson(Map<String, dynamic> json) {
    _validateDecaidShotExportShape(json);
    try {
      return ShotRecord.fromRecordedJson(json);
    } on FormatException catch (error, stack) {
      Error.throwWithStackTrace(
        UserFacingFormatException(error.message),
        stack,
      );
    }
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
    throw UserFacingFormatException(
      'Not a Decaid shot export (missing or invalid: ${missingFields.join(', ')}).$hint',
    );
  }
}
