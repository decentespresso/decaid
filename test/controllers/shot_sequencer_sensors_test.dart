import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/controllers/shot_sequencer.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/services/database/database.dart' hide ShotRecord;
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/test_de1.dart';
import '../helpers/test_scale.dart';
import '../helpers/test_scale_controller.dart';
import '../helpers/test_sensor.dart';

const _sensorId = 'BengleXYZ-puckestimator';
final _sampleTime = DateTime(2026, 1, 15, 8, 0);

class _FakeDiscoveryService extends DeviceDiscoveryService {
  @override
  Stream<List<Device>> get devices => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
}

class _TestDe1Controller extends De1Controller {
  final TestDe1 testDe1;

  _TestDe1Controller(this.testDe1, DeviceController devices)
    : super(controller: devices);

  @override
  De1Interface connectedDe1() => testDe1;

  @override
  Stream<De1Interface?> get de1 => BehaviorSubject.seeded(testDe1).stream;
}

class _StreamSensor extends TestSensor {
  final StreamController<Map<String, dynamic>> frames =
      StreamController.broadcast();

  _StreamSensor() : super(deviceId: _sensorId);

  @override
  Stream<Map<String, dynamic>> get data => frames.stream;

  @override
  Future<void> disconnect() => frames.close();
}

Profile _profile() => Profile(
  version: '2',
  title: 'Test Profile',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  targetVolumeCountStart: 0,
  tankTemperature: 0,
  targetWeight: 36,
  steps: [
    ProfileStepPressure(
      name: 'step1',
      transition: TransitionType.fast,
      volume: 0,
      seconds: 30,
      temperature: 93,
      sensor: TemperatureSensor.coffee,
      pressure: 9,
    ),
  ],
);

void main() {
  late AppDatabase db;
  late DeviceController devices;
  late TestDe1 testDe1;
  late TestScale testScale;
  late TestScaleController scaleController;
  late SensorController sensorController;
  late PersistenceController persistenceController;
  late ShotSequencer sequencer;
  late List<ShotSnapshot> samples;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    devices = DeviceController([_FakeDiscoveryService()]);
    testDe1 = TestDe1();
    testScale = TestScale();
    scaleController = TestScaleController(testScale);
    sensorController = SensorController(controller: devices);
    persistenceController = PersistenceController(
      storageService: DriftStorageService(db),
    );
    sequencer = ShotSequencer(
      scaleController: scaleController,
      de1controller: _TestDe1Controller(testDe1, devices),
      persistenceController: persistenceController,
      targetProfile: _profile(),
      sensorController: sensorController,
      targetYield: 36,
      bypassSAW: true,
      blockOnNoScale: false,
      weightFlowMultiplier: 0,
      volumeFlowMultiplier: 0,
      stepExitArbiterEnabled: false,
    );
    samples = [];
    sequencer.rawData.listen(samples.add);
  });

  tearDown(() async {
    sequencer.dispose();
    sensorController.dispose();
    scaleController.dispose();
    testScale.dispose();
    testDe1.dispose();
    await db.close();
  });

  Future<ShotSnapshot> takeSample() async {
    testDe1.emitSnapshot(
      testDe1.snapshotSubject.value.copyWith(
        timestamp: _sampleTime,
        state: const MachineStateSnapshot(
          state: MachineState.espresso,
          substate: MachineSubstate.pouring,
        ),
        pressure: 9,
      ),
    );
    await pumpEventQueue();
    return samples.last;
  }

  Future<void> emit(_StreamSensor sensor, Map<String, dynamic> frame) async {
    sensor.frames.add(frame);
    await pumpEventQueue();
  }

  Future<_StreamSensor> registerSensor() async {
    final sensor = _StreamSensor();
    await sensorController.register(sensor);
    return sensor;
  }

  group('non-finite sensor values', () {
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      test('a shot with a $value channel value still persists', () async {
        final sensor = await registerSensor();
        scaleController.emitWeight(12.5);
        await takeSample();
        await emit(sensor, {
          'puckResistance': value,
          'r1': 4.5,
          'bands': [value, 1.0],
          'fit': {'r2': value, 'n': 3},
        });
        await takeSample();

        await persistenceController.persistShot(
          ShotRecord(
            id: 'shot-1',
            timestamp: _sampleTime,
            measurements: List.of(samples),
            workflow: WorkflowController().currentWorkflow,
          ),
        );

        final row = await db.shotDao.getShotById('shot-1');
        expect(row, isNotNull);
        final stored = jsonDecode(row!.measurementsJson) as List;
        expect(stored, hasLength(samples.length));
        final last = stored.last as Map<String, dynamic>;
        expect(last['machine'], isNotNull);
        expect((last['machine'] as Map)['pressure'], 9);
        expect(last['scale'], isNotNull);
        expect((last['scale'] as Map)['weight'], 12.5);
        final channels = (last['sensors'] as Map)[_sensorId] as Map;
        expect(channels.containsKey('puckResistance'), isTrue);
        expect(channels['puckResistance'], isNull);
        expect(channels['r1'], 4.5);
        expect(channels['bands'], [null, 1.0]);
        expect(channels['fit'], {'r2': null, 'n': 3});
      });
    }
  });
}
