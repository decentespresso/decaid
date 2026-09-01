import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/mappers/shot_mapper.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  domain.ShotRecord makeRecord({String? stopReason}) {
    return domain.ShotRecord(
      id: 'shot-1',
      timestamp: DateTime.utc(2026, 6, 17, 9, 0),
      measurements: const [],
      workflow: WorkflowController().currentWorkflow,
      stopReason: stopReason,
    );
  }

  test('stopReason round-trips through the shots table', () async {
    await db.shotDao.insertShot(
      ShotMapper.toCompanion(makeRecord(stopReason: 'targetWeight')),
    );

    final row = await db.shotDao.getShotById('shot-1');
    final restored = ShotMapper.fromRow(row!);

    expect(restored.stopReason, 'targetWeight');
  });

  test('a shot persisted without a stopReason reads back null', () async {
    await db.shotDao.insertShot(ShotMapper.toCompanion(makeRecord()));

    final row = await db.shotDao.getShotById('shot-1');
    expect(ShotMapper.fromRow(row!).stopReason, isNull);
  });

  test('updateShot persists the record updatedAt, not a fresh now()', () async {
    await db.shotDao.insertShot(ShotMapper.toCompanion(makeRecord()));

    final editedAt = DateTime.utc(2026, 6, 17, 10, 30);
    await db.shotDao.updateShot(
      ShotMapper.toCompanion(
        makeRecord(stopReason: 'manual').copyWith(updatedAt: editedAt),
      ),
    );

    final row = await db.shotDao.getShotById('shot-1');
    expect(ShotMapper.fromRow(row!).updatedAt, editedAt);
  });

  test('storeShot stamps createdAt and updatedAt at insertion', () async {
    final storage = DriftStorageService(db);
    await storage.storeShot(makeRecord());

    final row = await db.shotDao.getShotById('shot-1');
    final restored = ShotMapper.fromRow(row!);

    expect(restored.createdAt, isNotNull);
    expect(restored.updatedAt, isNotNull);
    expect(restored.createdAt!.isUtc, isTrue);
    expect(restored.updatedAt!.isUtc, isTrue);
    expect(restored.createdAt, restored.updatedAt);
    expect(
      DateTime.now().toUtc().difference(restored.updatedAt!).inSeconds,
      lessThan(10),
    );
  });

  test(
    'legacy rows without timestamps expose the extraction-time fallback',
    () async {
      final workflow = WorkflowController().currentWorkflow;
      await db
          .into(db.shotRecords)
          .insert(
            ShotRecordsCompanion.insert(
              id: 'legacy-1',
              timestamp: DateTime.utc(2025, 3, 1, 12),
              workflowJson: workflow.toJson(),
              measurementsJson: '[]',
            ),
          );

      final row = await db.shotDao.getShotById('legacy-1');
      final restored = ShotMapper.fromRow(row!);

      expect(restored.createdAt, DateTime.utc(2025, 3, 1, 12));
      expect(restored.updatedAt, DateTime.utc(2025, 3, 1, 12));
    },
  );
}
