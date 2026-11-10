import 'dart:async';

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
    double? minEnjoyment,
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
    double? minEnjoyment,
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
  Future<void>? lookupGate;
  bool fail = false;

  @override
  Future<Grinder?> getGrinderById(String id) async {
    lookups.add(id);
    await lookupGate;
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

ShotRecord _shot(WorkflowContext? context, {String id = 'shot-1'}) {
  final base = WorkflowController().currentWorkflow;
  return ShotRecord(
    id: id,
    timestamp: DateTime.utc(2026, 5, 18, 12),
    measurements: const [],
    workflow: base.copyWith(id: base.id, context: context),
  );
}

void main() {
  late _FakeStorage storage;

  setUp(() => storage = _FakeStorage());

  WorkflowContext? storedContext() => storage.stored.single.workflow.context;

  test(
    'persistShot detaches workflow extras before grinder lookup awaits',
    () async {
      final lookup = Completer<void>();
      final grinders = _FakeGrinderStorage([
        _grinder(id: 'grinder-1', burrs: 'Core'),
      ])..lookupGate = lookup.future;
      final extras = <String, dynamic>{
        'plugin.grinder': {
          'feedingRate': 4.5,
          'rpmProfile': [900, 1200],
        },
      };
      final shot = _shot(
        WorkflowContext(
          grinderId: 'grinder-1',
          grinderModel: 'EG1',
          grinderRpm: 1200,
          extras: extras,
        ),
      );
      final controller = PersistenceController(
        storageService: storage,
        grinderStorageService: grinders,
      );
      addTearDown(controller.dispose);

      final persist = controller.persistShot(shot);
      (extras['plugin.grinder'] as Map<String, dynamic>)['feedingRate'] = 9.0;
      (extras['plugin.grinder'] as Map<String, dynamic>)['rpmProfile'][0] = 300;
      shot.workflow.steamSettings.duration = 99;
      shot.workflow.hotWaterData.volume = 999;
      shot.workflow.rinseData.flow = 0.1;
      lookup.complete();
      await persist;

      final stored = storage.stored.single;
      expect(stored.workflow.steamSettings.duration, 50);
      expect(stored.workflow.hotWaterData.volume, 50);
      expect(stored.workflow.rinseData.flow, 6.0);
      expect(storedContext()?.grinderRpm, 1200);
      expect(storedContext()?.extras, {
        'plugin.grinder': {
          'feedingRate': 4.5,
          'rpmProfile': [900, 1200],
        },
      });
    },
  );

  test(
    'persistShot keeps saved and repeated workflow snapshots independent',
    () async {
      final grinders = _FakeGrinderStorage([
        _grinder(id: 'grinder-1', burrs: 'Core'),
      ]);
      final controller = PersistenceController(
        storageService: storage,
        grinderStorageService: grinders,
      );
      addTearDown(controller.dispose);

      final extras = <String, dynamic>{
        'plugin.grinder': {
          'feedingRate': 4.5,
          'rpmProfile': [900, 1200],
        },
      };
      await controller.persistShot(
        _shot(
          WorkflowContext(
            grinderId: 'grinder-1',
            grinderModel: 'EG1',
            grinderSetting: '5',
            grinderRpm: 1200,
            extras: extras,
          ),
        ),
      );

      grinders.grinders[0] = grinders.grinders[0].copyWith(burrs: 'SSP HU');
      (extras['plugin.grinder'] as Map<String, dynamic>)['feedingRate'] = 6.0;
      (extras['plugin.grinder'] as Map<String, dynamic>)['rpmProfile'][0] =
          1100;
      (extras['plugin.grinder'] as Map<String, dynamic>)['rpmProfile'][1] =
          1400;

      await controller.persistShot(
        _shot(
          WorkflowContext(
            grinderId: 'grinder-1',
            grinderModel: 'EG1',
            grinderBurrs: 'Core',
            grinderSetting: '7',
            grinderRpm: 1400,
            extras: extras,
          ),
          id: 'shot-2',
        ),
      );

      expect(storage.stored, hasLength(2));
      final first = storage.stored[0].workflow.context;
      expect(first?.grinderId, 'grinder-1');
      expect(first?.grinderModel, 'EG1');
      expect(first?.grinderBurrs, 'Core');
      expect(first?.grinderSetting, '5');
      expect(first?.grinderRpm, 1200);
      expect(first?.extras, {
        'plugin.grinder': {
          'feedingRate': 4.5,
          'rpmProfile': [900, 1200],
        },
      });

      final repeated = storage.stored[1].workflow.context;
      expect(repeated?.grinderId, 'grinder-1');
      expect(repeated?.grinderModel, 'EG1');
      expect(repeated?.grinderBurrs, 'SSP HU');
      expect(repeated?.grinderSetting, '7');
      expect(repeated?.grinderRpm, 1400);
      expect(repeated?.extras, {
        'plugin.grinder': {
          'feedingRate': 6.0,
          'rpmProfile': [1100, 1400],
        },
      });
    },
  );

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

  test('persistShot refreshes a burrs snapshot inherited by Repeat', () async {
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

    expect(
      storedContext()?.grinderBurrs,
      'SSP HU',
      reason: 'the burrs were swapped since the repeated shot was recorded',
    );
    expect(grinders.lookups, ['grinder-1']);
  });

  test(
    'persistShot clears an inherited snapshot when the grinder has no burrs',
    () async {
      final grinders = _FakeGrinderStorage([_grinder(id: 'grinder-1')]);
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

      expect(storedContext()?.grinderBurrs, isNull);
      expect(storedContext()?.grinderModel, 'EG1');
    },
  );

  test('persistShot takes the burrs of a newly selected grinder, not the inherited one', () async {
    final grinders = _FakeGrinderStorage([
      _grinder(id: 'grinder-1', burrs: 'Core'),
      _grinder(id: 'grinder-2', burrs: 'MP'),
    ]);
    final controller = PersistenceController(
      storageService: storage,
      grinderStorageService: grinders,
    );
    addTearDown(controller.dispose);

    await controller.persistShot(
      _shot(
        const WorkflowContext(
          grinderId: 'grinder-2',
          grinderModel: 'P64',
          grinderBurrs: 'Core',
        ),
      ),
    );

    expect(storedContext()?.grinderBurrs, 'MP');
  });

  test('persistShot clears an inherited snapshot it cannot verify', () async {
    final grinders = _FakeGrinderStorage([
      _grinder(id: 'grinder-1', burrs: 'Core'),
    ])..fail = true;
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

    expect(
      storedContext()?.grinderBurrs,
      isNull,
      reason: 'an unverifiable snapshot must not claim burrs it cannot confirm',
    );
  });

  test(
    'persistShot leaves burrs recorded without a grinder link alone',
    () async {
      final grinders = _FakeGrinderStorage([
        _grinder(id: 'grinder-1', burrs: 'Core'),
      ]);
      final controller = PersistenceController(
        storageService: storage,
        grinderStorageService: grinders,
      );
      addTearDown(controller.dispose);

      await controller.persistShot(
        _shot(
          const WorkflowContext(grinderModel: 'EG1', grinderBurrs: 'Stock'),
        ),
      );

      expect(storedContext()?.grinderBurrs, 'Stock');
      expect(grinders.lookups, isEmpty);
    },
  );

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
    expect(storedContext()?.grinderRpm, isNull);
    expect(grinders.lookups, isEmpty);
  });

  test(
    'persistShot preserves a manual grinder without telemetry defaults',
    () async {
      final controller = PersistenceController(storageService: storage);
      addTearDown(controller.dispose);

      await controller.persistShot(
        _shot(
          const WorkflowContext(
            grinderModel: 'Manual hand grinder',
            grinderSetting: '12',
          ),
        ),
      );

      expect(storedContext()?.grinderId, isNull);
      expect(storedContext()?.grinderRpm, isNull);
      expect(storedContext()?.extras, isNull);
    },
  );

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
