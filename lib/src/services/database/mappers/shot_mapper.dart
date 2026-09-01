import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_record.dart' as domain;
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/workflow.dart' as domain_workflow;
import 'package:reaprime/src/services/database/database.dart' as db;

class ShotMapper {
  static domain.ShotRecord fromRow(db.ShotRecord row) {
    final workflow = domain_workflow.Workflow.fromJson(row.workflowJson);

    ShotAnnotations? annotations;
    if (row.annotationsJson != null) {
      annotations = ShotAnnotations.fromJson(row.annotationsJson!);
    }

    final measurements = (jsonDecode(row.measurementsJson) as List)
        .map((e) => ShotSnapshot.fromJson(e as Map<String, dynamic>))
        .toList();

    return domain.ShotRecord(
      id: row.id,
      timestamp: row.timestamp,
      createdAt: row.createdAt ?? row.timestamp,
      updatedAt: row.updatedAt ?? row.createdAt ?? row.timestamp,
      measurements: measurements,
      workflow: workflow,
      annotations: annotations,
      stopReason: row.stopReason,
    );
  }

  static db.ShotRecordsCompanion toCompanion(domain.ShotRecord record) {
    final ctx = record.workflow.context;
    return db.ShotRecordsCompanion(
      id: Value(record.id),
      timestamp: Value(record.timestamp),
      createdAt: Value(record.createdAt),
      updatedAt: Value(record.updatedAt),

      profileTitle: Value(record.workflow.profile.title),
      grinderId: Value(ctx?.grinderId),
      grinderModel: Value(ctx?.grinderModel),
      grinderSetting: Value(ctx?.grinderSetting),
      beanBatchId: Value(ctx?.beanBatchId),
      coffeeName: Value(ctx?.coffeeName),
      coffeeRoaster: Value(ctx?.coffeeRoaster),
      targetDoseWeight: Value(ctx?.targetDoseWeight),
      targetYield: Value(ctx?.targetYield),
      enjoyment: Value(record.annotations?.enjoyment),
      espressoNotes: Value(record.annotations?.espressoNotes),
      stopReason: Value(record.stopReason),

      workflowJson: Value(record.workflow.toJson()),
      annotationsJson: Value(record.annotations?.toJson()),
      measurementsJson: Value(
        jsonEncode(record.measurements.map((m) => m.toJson()).toList()),
      ),
    );
  }
}
