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
    expect(
      DateTime.now().toUtc().difference(restored.updatedAt!).inSeconds,
      lessThan(10),
    );
  });
}
