import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/grinder.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';

class _FakeStorage implements StorageService {
  final List<ShotRecord> stored = [];

  @override
  Future<void> storeShot(ShotRecord record) async {
    stored.add(record);
  }

  @override
  Future<void> updateShot(ShotRecord record) async {}
  @override
  Future<void> deleteShot(String id) async {}
  @override
  Future<List<String>> getShotIds() async => [];
  @override
  Future<List<ShotRecord>> getAllShots() async => [];
  @override
  Future<ShotRecord?> getShot(String id) async => null;
  @override
  Future<void> storeCurrentWorkflow(Workflow workflow) async {}
  @override
  Future<Workflow?> loadCurrentWorkflow() async => null;
  @override
  Future<List<ShotRecord>> getShotsPaginated({
    int limit = 20,
    int offset = 0,
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    bool ascending = false,
  }) async => [];
  @override
  Future<int> countShots({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
  }) async => 0;
  @override
  Future<ShotRecord?> getLatestShot() async => null;
  @override
  Future<ShotRecord?> getLatestShotMeta() async => null;

  @override
  Future<void> storeSteam(SteamRecord record) async {}
  @override
  Future<void> updateSteam(SteamRecord record) async {}
  @override
  Future<void> deleteSteam(String id) async {}
  @override
  Future<List<String>> getSteamIds() async => [];
  @override
  Future<List<SteamRecord>> getAllSteams() async => [];
  @override
  Future<SteamRecord?> getSteam(String id) async => null;
  @override
  Future<SteamRecord?> getLatestSteam() async => null;
  @override
  Future<SteamRecord?> getLatestSteamMeta() async => null;
}

class _FakeGrinderStorage implements GrinderStorageService {
  _FakeGrinderStorage(this.grinders);

  final List<Grinder> grinders;
  final List<String> lookups = [];
  bool fail = false;

  @override
  Future<Grinder?> getGrinderById(String id) async {
    lookups.add(id);
    if (fail) throw StateError('grinder lookup failed');
    return grinders.where((g) => g.id == id).firstOrNull;
  }

  @override
  Future<List<Grinder>> getAllGrinders({bool includeArchived = false}) async =>
      grinders;
  @override
  Stream<List<Grinder>> watchAllGrinders({bool includeArchived = false}) =>
      throw UnimplementedError();
  @override
  Future<void> insertGrinder(Grinder grinder) async {}
  @override
  Future<void> updateGrinder(Grinder grinder) async {}
  @override
  Future<void> deleteGrinder(String id) async {}
}

Grinder _grinder({required String id, String? burrs}) => Grinder(
  id: id,
  model: 'EG1',
  burrs: burrs,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

ShotRecord _shot(WorkflowContext? context) {
  final base = WorkflowController().currentWorkflow;
  return ShotRecord(
    id: 'shot-1',
    timestamp: DateTime.utc(2026, 5, 18, 12),
    measurements: const [],
    workflow: base.copyWith(id: base.id, context: context),
  );
}

void main() {
  late _FakeStorage storage;

  setUp(() => storage = _FakeStorage());

  WorkflowContext? storedContext() => storage.stored.single.workflow.context;

  test('persistShot snapshots the linked grinder burrs', () async {
    final grinders = _FakeGrinderStorage([
      _grinder(id: 'grinder-1', burrs: 'Core'),
    ]);
    final controller = PersistenceController(
      storageService: storage,
      grinderStorageService: grinders,
    );
    addTearDown(controller.dispose);

    await controller.persistShot(
      _shot(const WorkflowContext(grinderId: 'grinder-1', grinderModel: 'EG1')),
    );

    expect(storedContext()?.grinderBurrs, 'Core');
    expect(grinders.lookups, ['grinder-1']);
  });

  test('persistShot keeps a burrs value the context already carries', () async {
    final grinders = _FakeGrinderStorage([
      _grinder(id: 'grinder-1', burrs: 'SSP HU'),
    ]);
    final controller = PersistenceController(
      storageService: storage,
      grinderStorageService: grinders,
    );
    addTearDown(controller.dispose);

    await controller.persistShot(
      _shot(
        const WorkflowContext(
          grinderId: 'grinder-1',
          grinderModel: 'EG1',
          grinderBurrs: 'Core',
        ),
      ),
    );

    expect(storedContext()?.grinderBurrs, 'Core');
    expect(grinders.lookups, isEmpty);
  });

  test(
    'persistShot stores the shot unchanged when burrs are unavailable',
    () async {
      final grinders = _FakeGrinderStorage([_grinder(id: 'grinder-1')]);
      final controller = PersistenceController(
        storageService: storage,
        grinderStorageService: grinders,
      );
      addTearDown(controller.dispose);

      await controller.persistShot(
        _shot(
          const WorkflowContext(grinderId: 'grinder-1', grinderModel: 'EG1'),
        ),
      );

      expect(storedContext()?.grinderBurrs, isNull);
      expect(storedContext()?.grinderModel, 'EG1');
    },
  );

  test('persistShot survives a failing grinder lookup', () async {
    final grinders = _FakeGrinderStorage([
      _grinder(id: 'grinder-1', burrs: 'Core'),
    ])..fail = true;
    final controller = PersistenceController(
      storageService: storage,
      grinderStorageService: grinders,
    );
    addTearDown(controller.dispose);

    await controller.persistShot(
      _shot(const WorkflowContext(grinderId: 'grinder-1', grinderModel: 'EG1')),
    );

    expect(storage.stored, hasLength(1));
    expect(storedContext()?.grinderBurrs, isNull);
  });

  test('persistShot does not look up a grinder for an unlinked shot', () async {
    final grinders = _FakeGrinderStorage([
      _grinder(id: 'grinder-1', burrs: 'Core'),
    ]);
    final controller = PersistenceController(
      storageService: storage,
      grinderStorageService: grinders,
    );
    addTearDown(controller.dispose);

    await controller.persistShot(
      _shot(const WorkflowContext(grinderModel: 'EG1')),
    );

    expect(storedContext()?.grinderBurrs, isNull);
    expect(grinders.lookups, isEmpty);
  });

  test('persistShot works without a grinder storage service', () async {
    final controller = PersistenceController(storageService: storage);
    addTearDown(controller.dispose);

    await controller.persistShot(
      _shot(const WorkflowContext(grinderId: 'grinder-1', grinderModel: 'EG1')),
    );

    expect(storage.stored, hasLength(1));
    expect(storedContext()?.grinderBurrs, isNull);
  });
}
