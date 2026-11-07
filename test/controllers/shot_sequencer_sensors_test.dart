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
  StreamController<Map<String, dynamic>> frames = StreamController.broadcast();
  final bool closeOnDisconnect;

  _StreamSensor({this.closeOnDisconnect = true}) : super(deviceId: _sensorId);

  @override
  Stream<Map<String, dynamic>> get data => frames.stream;

  @override
  Future<void> disconnect() async {
    if (closeOnDisconnect) await frames.close();
  }
}

class _SubjectSensor extends TestSensor {
  BehaviorSubject<Map<String, dynamic>> subject;

  _SubjectSensor(Map<String, dynamic> seed)
    : subject = BehaviorSubject.seeded(seed),
      super(deviceId: _sensorId);

  @override
  Stream<Map<String, dynamic>> get data => subject.stream;
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

  Future<List<ShotSnapshot>> takeSamplesWithoutDrain(int count) async {
    final first = samples.length;
    for (var i = 0; i < count; i++) {
      testDe1.emitSnapshot(
        testDe1.snapshotSubject.value.copyWith(timestamp: _sampleTime),
      );
    }
    await pumpEventQueue();
    return samples.sublist(first);
  }

  Future<void> emit(_StreamSensor sensor, Map<String, dynamic> frame) async {
    sensor.frames.add(frame);
    await pumpEventQueue();
  }

  Future<_StreamSensor> registerSensor({bool closeOnDisconnect = true}) async {
    final sensor = _StreamSensor(closeOnDisconnect: closeOnDisconnect);
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

  group('replaced sensor', () {
    test('a sensor replaced under the same id is followed', () async {
      final first = await registerSensor();
      await takeSample();
      await emit(first, {'r1': 10.0});
      expect((await takeSample()).sensors![_sensorId]!['r1'], 10.0);

      final second = await registerSensor();
      await takeSample();
      await emit(second, {'r1': 20.0});

      expect((await takeSample()).sensors![_sensorId]!['r1'], 20.0);
      expect(first.frames.hasListener, isFalse);
    });

    test('a replaced sensor that keeps its stream open is released', () async {
      final first = await registerSensor(closeOnDisconnect: false);
      await takeSample();
      await emit(first, {'r1': 10.0});
      await takeSample();

      final second = await registerSensor(closeOnDisconnect: false);
      final afterReplace = await takeSample();
      await emit(first, {'r1': 11.0});
      await emit(second, {'r1': 20.0});

      expect(afterReplace.sensors?[_sensorId], isNull);
      expect(first.frames.hasListener, isFalse);
      expect((await takeSample()).sensors![_sensorId]!['r1'], 20.0);
    });
  });

  group('removed or failed sensor', () {
    Future<ShotSnapshot> recordOneFrame(_StreamSensor sensor) async {
      await takeSample();
      await emit(sensor, {'r1': 4.5});
      final before = await takeSample();
      expect(before.sensors![_sensorId]!['r1'], 4.5);
      return before;
    }

    test('an unregistered sensor stops adding frames', () async {
      final sensor = await registerSensor();
      final before = await recordOneFrame(sensor);

      await sensorController.unregister(_sensorId);
      final after = await takeSample();

      expect(after.sensors?[_sensorId], isNull);
      expect(before.sensors![_sensorId]!['r1'], 4.5);
    });

    test(
      'an unregistered sensor that keeps its stream open is released',
      () async {
        final sensor = await registerSensor(closeOnDisconnect: false);
        final before = await recordOneFrame(sensor);

        await sensorController.unregister(_sensorId);
        final after = await takeSample();
        await emit(sensor, {'r1': 5.0});

        expect(after.sensors?[_sensorId], isNull);
        expect(sensor.frames.hasListener, isFalse);
        expect((await takeSample()).sensors?[_sensorId], isNull);
        expect(before.sensors![_sensorId]!['r1'], 4.5);
      },
    );

    test('a sensor whose stream errors stops adding frames', () async {
      final sensor = await registerSensor();
      final before = await recordOneFrame(sensor);

      sensor.frames.addError(StateError('link lost'));
      await pumpEventQueue();
      final after = await takeSample();

      expect(after.sensors?[_sensorId], isNull);
      expect(before.sensors![_sensorId]!['r1'], 4.5);
    });

    test(
      'a sensor that sends a frame after an error is recorded again',
      () async {
        final sensor = await registerSensor();
        await recordOneFrame(sensor);
        sensor.frames.addError(StateError('link lost'));
        await pumpEventQueue();
        await takeSample();

        await emit(sensor, {'r1': 5.0});

        expect((await takeSample()).sensors![_sensorId]!['r1'], 5.0);
      },
    );

    test('a sensor whose stream closes stops adding frames', () async {
      final sensor = await registerSensor();
      final before = await recordOneFrame(sensor);

      await sensor.frames.close();
      await pumpEventQueue();
      final after = await takeSample();

      expect(after.sensors?[_sensorId], isNull);
      expect(before.sensors![_sensorId]!['r1'], 4.5);
    });

    test(
      'a closed replaying stream does not put its last frame back',
      () async {
        final sensor = _SubjectSensor({'r1': 4.5});
        await sensorController.register(sensor);
        await takeSample();
        expect((await takeSample()).sensors![_sensorId]!['r1'], 4.5);

        await sensor.subject.close();
        await pumpEventQueue();
        final after = await takeSamplesWithoutDrain(6);

        expect(after, hasLength(6));
        for (final sample in after) {
          expect(sample.sensors?[_sensorId], isNull);
        }
      },
    );

    test('a closed replaying sensor registered again is not bound', () async {
      final sensor = _SubjectSensor({'r1': 4.5});
      await sensorController.register(sensor);
      await takeSample();
      await sensor.subject.close();
      await pumpEventQueue();
      await takeSample();

      await sensorController.unregister(_sensorId);
      await takeSample();
      await sensorController.register(sensor);
      final after = await takeSamplesWithoutDrain(6);

      for (final sample in after) {
        expect(sample.sensors?[_sensorId], isNull);
      }
    });

    test(
      'a replaying sensor that opens a new stream is recorded again',
      () async {
        final sensor = _SubjectSensor({'r1': 4.5});
        await sensorController.register(sensor);
        await takeSample();
        await sensor.subject.close();
        await pumpEventQueue();
        await takeSamplesWithoutDrain(3);

        sensor.subject = BehaviorSubject.seeded({'r1': 7.0});
        await takeSample();

        expect((await takeSample()).sensors![_sensorId]!['r1'], 7.0);
      },
    );

    test(
      'a sensor that opens a new stream after closing is recorded again',
      () async {
        final sensor = await registerSensor();
        await recordOneFrame(sensor);
        await sensor.frames.close();
        await pumpEventQueue();
        await takeSample();

        sensor.frames = StreamController.broadcast();
        await takeSample();
        await emit(sensor, {'r1': 6.0});

        expect((await takeSample()).sensors![_sensorId]!['r1'], 6.0);
      },
    );
  });
}
