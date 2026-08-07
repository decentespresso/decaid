import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/steam_record.dart' as domain;
import 'package:reaprime/src/models/data/steam_snapshot.dart';
import 'package:reaprime/src/models/data/workflow.dart' as domain_workflow;
import 'package:reaprime/src/services/database/database.dart' as db;

class SteamMapper {
  static domain.SteamRecord fromRow(db.SteamRecord row) {
    final workflow = domain_workflow.Workflow.fromJson(row.workflowJson);

    ShotAnnotations? annotations;
    if (row.annotationsJson != null) {
      annotations = ShotAnnotations.fromJson(row.annotationsJson!);
    }

    final measurements = (jsonDecode(row.measurementsJson) as List)
        .map((e) => SteamSnapshot.fromJson(e as Map<String, dynamic>))
        .toList();

    return domain.SteamRecord(
      id: row.id,
      timestamp: row.timestamp,
      measurements: measurements,
      workflow: workflow,
      annotations: annotations,
    );
  }

  static db.SteamRecordsCompanion toCompanion(domain.SteamRecord record) {
    return db.SteamRecordsCompanion(
      id: Value(record.id),
      timestamp: Value(record.timestamp),
      workflowJson: Value(record.workflow.toJson()),
      annotationsJson: Value(record.annotations?.toJson()),
      measurementsJson: Value(
        jsonEncode(record.measurements.map((m) => m.toJson()).toList()),
      ),
    );
  }
}
