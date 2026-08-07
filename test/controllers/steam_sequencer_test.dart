import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/controllers/steam_sequencer.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
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

  void emit(De1Interface? device) => _subj.add(device);
}

class _TestMachine implements De1Interface {
  _TestMachine({this.id = 'test-machine'});

  final String id;
  @override
  String get deviceId => id;
  @override
  String get name => 'TestMachine';
  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;

  final BehaviorSubject<MachineSnapshot> _snap = BehaviorSubject();
  @override
  Stream<MachineSnapshot> get currentSnapshot => _snap.stream;

  final List<MachineState> requested = [];

  @override
  Future<void> requestState(MachineState state) async {
    requested.add(state);
  }

  void emit(MachineSnapshot s) => _snap.add(s);

  @override
  Future<void> dispose() async => _snap.close();

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<bool> get ready => Stream<bool>.value(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BengleTestMachine extends _TestMachine implements BengleInterface {
  _BengleTestMachine() : super(id: 'bengle-test');
}

class _TestSensor implements Sensor {
  _TestSensor() : id = 'test-sensor';
  final String id;
  @override
  String get deviceId => id;
  @override
  String get name => 'TestSensor';
  @override
  DeviceType get type => DeviceType.sensor;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;
  final BehaviorSubject<Map<String, dynamic>> _data = BehaviorSubject();
  @override
  Stream<Map<String, dynamic>> get data => _data.stream;
  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);
  @override
  SensorInfo get info => SensorInfo(
    name: name,
    vendor: 'test',
    dataChannels: const [],
    commands: const [],
  );
  @override
  Future<Map<String, dynamic>> execute(
    String c,
    Map<String, dynamic>? p,
  ) async => const {};
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}
  void emit(double celsius) => _data.add({
    'timestamp': DateTime.now().toIso8601String(),
    'temperature': celsius,
  });
}

class _RecordingStorage implements StorageService {
  final List<SteamRecord> persisted = [];

  @override
  Future<void> storeSteam(SteamRecord record) async => persisted.add(record);
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

MachineSnapshot _snap({
  required MachineState state,
  MachineSubstate substate = MachineSubstate.idle,
  int steamTemperature = 140,
  DateTime? at,
}) {
  return MachineSnapshot(
    timestamp: at ?? DateTime.now(),
    state: MachineStateSnapshot(state: state, substate: substate),
    flow: 0,
    pressure: 0,
    targetFlow: 0,
    targetPressure: 0,
    mixTemperature: 90,
    groupTemperature: 90,
    targetMixTemperature: 93,
    targetGroupTemperature: 93,
    profileFrame: 0,
    steamTemperature: steamTemperature,
  );
}

void main() {
  late _StubDe1Controller de1;
  late SensorController sensors;
  late WorkflowController workflow;
  late PersistenceController persistence;
  late _RecordingStorage storage;
  late SteamSequencer sequencer;

  setUp(() async {
    de1 = _StubDe1Controller();
    final emptyController = DeviceController([_EmptyDiscovery()]);
    await emptyController.initialize();
    sensors = SensorController(controller: emptyController);
    workflow = WorkflowController();
    storage = _RecordingStorage();
    persistence = PersistenceController(storageService: storage);
    sequencer = SteamSequencer(
      de1Controller: de1,
      sensorController: sensors,
      workflowController: workflow,
      persistenceController: persistence,
    );
  });

  tearDown(() async {
    await sequencer.dispose();
    persistence.dispose();
    sensors.dispose();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('useFwAutonomousStop predicate truth table', () {
    test('false on non-Bengle machines regardless of other inputs', () {
      final m = _TestMachine();
      expect(
        sequencer.useFwAutonomousStop(
          machine: m,
          probeAttached: true,
          stopAtTemperature: 60,
        ),
        isFalse,
      );
      m.dispose();
    });

    test('false when stop target is 0 (off)', () {
      final m = _BengleTestMachine();
      expect(
        sequencer.useFwAutonomousStop(
          machine: m,
          probeAttached: true,
          stopAtTemperature: 0,
        ),
        isFalse,
      );
      m.dispose();
    });

    test('false when probe is not attached', () {
      final m = _BengleTestMachine();
      expect(
        sequencer.useFwAutonomousStop(
          machine: m,
          probeAttached: false,
          stopAtTemperature: 60,
        ),
        isFalse,
      );
      m.dispose();
    });

    test('false today because MMR slot is stubbed', () {
      final m = _BengleTestMachine();
      expect(
        sequencer.useFwAutonomousStop(
          machine: m,
          probeAttached: true,
          stopAtTemperature: 60,
        ),
        isFalse,
        reason: 'FW slot is still 0x00000000 — predicate must stay false',
      );
      m.dispose();
    });
  });

  group('record lifecycle', () {
    test(
      'opens on entering steam and finalizes on returning to idle',
      () async {
        final m = _TestMachine();
        de1.emit(m);
        await settle();

        m.emit(_snap(state: MachineState.idle));
        await settle();
        expect(sequencer.isRecording, isFalse);

        m.emit(_snap(state: MachineState.steam));
        await settle();
        expect(sequencer.isRecording, isTrue);

        m.emit(_snap(state: MachineState.steam));
        m.emit(_snap(state: MachineState.idle));
        await settle();

        expect(sequencer.isRecording, isFalse);
        expect(storage.persisted, hasLength(1));
        expect(storage.persisted.first.measurements.length, greaterThan(0));
        m.dispose();
      },
    );

    test('finalizes on steam → sleep and on steam → error', () async {
      for (final exitState in [MachineState.sleeping, MachineState.error]) {
        storage.persisted.clear();
        final m = _TestMachine();
        de1.emit(m);
        await settle();

        m.emit(_snap(state: MachineState.steam));
        await settle();
        m.emit(_snap(state: exitState));
        await settle();

        expect(
          storage.persisted,
          hasLength(1),
          reason: 'should persist on steam → $exitState',
        );
        await sequencer.dispose();
        sequencer = SteamSequencer(
          de1Controller: de1,
          sensorController: sensors,
          workflowController: workflow,
          persistenceController: persistence,
        );
        m.dispose();
      }
    });

    test('discards record on machine disconnect mid-steam', () async {
      final m = _TestMachine();
      de1.emit(m);
      await settle();

      m.emit(_snap(state: MachineState.steam));
      await settle();
      expect(sequencer.isRecording, isTrue);

      de1.emit(null);
      await settle();

      expect(sequencer.isRecording, isFalse);
      expect(
        storage.persisted,
        isEmpty,
        reason: 'mid-steam disconnect must not persist',
      );
      m.dispose();
    });
  });

  group('snapshot collection', () {
    test('milkTemperature stays null when no sensor registered', () async {
      final m = _TestMachine();
      de1.emit(m);
      await settle();
      m.emit(_snap(state: MachineState.steam));
      await settle();
      m.emit(_snap(state: MachineState.idle));
      await settle();

      expect(storage.persisted, hasLength(1));
      expect(
        storage.persisted.first.measurements.every(
          (m) => m.milkTemperature == null,
        ),
        isTrue,
      );
      m.dispose();
    });

    test('milkTemperature picks up first registered sensor', () async {
      final probe = _TestSensor();
      await sensors.register(probe);

      final m = _TestMachine();
      de1.emit(m);
      await settle();
      m.emit(_snap(state: MachineState.steam));
      await settle();
      probe.emit(55.0);
      await settle();
      m.emit(_snap(state: MachineState.steam));
      await settle();
      m.emit(_snap(state: MachineState.idle));
      await settle();

      expect(storage.persisted, hasLength(1));
      final last = storage.persisted.first.measurements.last;
      expect(last.milkTemperature, equals(55.0));
    });
  });

  group('app-side stop', () {
    test('no stop fires when no sensor registered', () async {
      workflow.updateWorkflow(
        steamSettings: workflow.currentWorkflow.steamSettings.copyWith(
          stopAtTemperature: 60.0,
        ),
      );
      final m = _TestMachine();
      de1.emit(m);
      await settle();
      m.emit(_snap(state: MachineState.steam));
      await settle();

      expect(m.requested, isEmpty);
      m.dispose();
    });

    test('requests idle when first sensor crosses target', () async {
      workflow.updateWorkflow(
        steamSettings: workflow.currentWorkflow.steamSettings.copyWith(
          stopAtTemperature: 60.0,
        ),
      );
      final probe = _TestSensor();
      await sensors.register(probe);

      final m = _TestMachine();
      de1.emit(m);
      await settle();

      m.emit(_snap(state: MachineState.steam));
      await settle();
      probe.emit(40.0);
      m.emit(_snap(state: MachineState.steam));
      await settle();
      expect(m.requested, isEmpty);

      probe.emit(65.0);
      m.emit(_snap(state: MachineState.steam));
      await settle();

      expect(m.requested, contains(MachineState.idle));
      m.dispose();
    });
  });
}
