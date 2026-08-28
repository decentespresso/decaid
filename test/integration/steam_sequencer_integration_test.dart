import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/bengle_probe_bridge.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/controllers/steam_sequencer.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:rxdart/rxdart.dart';

class _EmptyDiscovery extends DeviceDiscoveryService {
  @override
  Stream<List<Device>> get devices => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
}

class _StubDe1Controller extends De1Controller {
  _StubDe1Controller()
    : _subj = BehaviorSubject.seeded(null),
      super(controller: DeviceController([_EmptyDiscovery()]));

  final BehaviorSubject<De1Interface?> _subj;

  @override
  Stream<De1Interface?> get de1 => _subj.stream;
  @override
  Future<void> requestMachineState(MachineState state) {
    return _subj.value!.requestState(state);
  }

  void emit(De1Interface? device) => _subj.add(device);
}

void main() {
  group('SteamSequencer integration', () {
    late AppDatabase db;
    late DriftStorageService storage;
    late PersistenceController persistence;
    late SensorController sensors;
    late WorkflowController workflow;
    late _StubDe1Controller de1;
    late BengleProbeBridge probeBridge;
    late SteamSequencer sequencer;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = DriftStorageService(db);
      persistence = PersistenceController(storageService: storage);
      final emptyController = DeviceController([_EmptyDiscovery()]);
      await emptyController.initialize();
      sensors = SensorController(controller: emptyController);
      workflow = WorkflowController();
      de1 = _StubDe1Controller();
      probeBridge = BengleProbeBridge(
        de1Controller: de1,
        sensorController: sensors,
      );
      sequencer = SteamSequencer(
        de1Controller: de1,
        sensorController: sensors,
        workflowController: workflow,
        persistenceController: persistence,
      );
    });

    tearDown(() async {
      await sequencer.dispose();
      await probeBridge.dispose();
      sensors.dispose();
      persistence.dispose();
      await db.close();
    });

    test(
      'full steaming session persists SteamRecord with probe data',
      () async {
        final bengle = MockBengle();
        await bengle.onConnect();
        de1.emit(bengle);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          sensors.sensors,
          isNotEmpty,
          reason: 'probe bridge should have registered BengleMilkProbe',
        );

        await bengle.setStopAtTemperatureTarget(15.0);
        await bengle.requestState(MachineState.steam);
        await Future<void>.delayed(const Duration(seconds: 4));

        await bengle.currentSnapshot
            .firstWhere((s) => s.state.state == MachineState.idle)
            .timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);

        final ids = await db.steamDao.getAllSteamIds();
        expect(ids, hasLength(1));

        final record = await db.steamDao.getLatestSteam();
        expect(record, isNotNull);
        expect(record!.measurementsJson, contains('milkTemperature'));

        await bengle.onDisconnect();
      },
    );
  });
}
