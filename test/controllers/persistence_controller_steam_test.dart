import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';

class _FakeStorage implements StorageService {
  final List<SteamRecord> stored = [];
  final List<SteamRecord> updated = [];
  final List<String> deleted = [];

  @override
  Future<void> storeSteam(SteamRecord record) async {
    stored.add(record);
  }

  @override
  Future<void> updateSteam(SteamRecord record) async {
    updated.add(record);
  }

  @override
  Future<void> deleteSteam(String id) async {
    deleted.add(id);
  }

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

  @override
  Future<void> storeShot(ShotRecord record) async {}
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
}

SteamRecord _record(String id) => SteamRecord(
  id: id,
  timestamp: DateTime.utc(2026, 5, 18, 12, 0, 0),
  measurements: const [],
  workflow: WorkflowController().currentWorkflow,
);

void main() {
  late _FakeStorage storage;
  late PersistenceController controller;

  setUp(() {
    storage = _FakeStorage();
    controller = PersistenceController(storageService: storage);
  });

  tearDown(() => controller.dispose());

  test('persistSteam stores via service and emits steamsChanged', () async {
    final events = <void>[];
    final sub = controller.steamsChanged.listen(events.add);
    await controller.persistSteam(_record('s-1'));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(storage.stored, hasLength(1));
    expect(storage.stored.first.id, equals('s-1'));
    expect(events, hasLength(1));
  });

  test('updateSteam delegates and emits steamsChanged', () async {
    final events = <void>[];
    final sub = controller.steamsChanged.listen(events.add);
    await controller.updateSteam(_record('s-2'));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(storage.updated, hasLength(1));
    expect(events, hasLength(1));
  });

  test('deleteSteam delegates and emits steamsChanged', () async {
    final events = <void>[];
    final sub = controller.steamsChanged.listen(events.add);
    await controller.deleteSteam('s-3');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(storage.deleted, equals(['s-3']));
    expect(events, hasLength(1));
  });
}
