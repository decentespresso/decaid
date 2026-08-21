import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/connection_timings.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

class _SilentShotSettingsDe1 extends TestDe1 {
  _SilentShotSettingsDe1() : super(deviceId: 'silent-de1', name: 'SilentDe1');

  final _silent = StreamController<De1ShotSettings>.broadcast();

  int setSteamFlowCalls = 0;
  int setFlushFlowCalls = 0;

  @override
  Stream<De1ShotSettings> get shotSettings => _silent.stream;

  @override
  Future<void> setSteamFlow(double value) async {
    setSteamFlowCalls++;
  }

  @override
  Future<void> setFlushFlow(double value) async {
    setFlushFlowCalls++;
  }

  @override
  Future<void> setFlushTimeout(double value) async {}

  @override
  Future<void> setFlushTemperature(double value) async {}

  @override
  Future<void> dispose() async {
    await _silent.close();
    await super.dispose();
  }
}

Profile _profile() => Profile(
  version: '2',
  title: 'test',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  steps: const [],
  targetVolumeCountStart: 0,
  tankTemperature: 0,
);

Workflow _workflow({required int steamDuration}) => Workflow(
  id: 'wf',
  name: 'wf',
  profile: _profile(),
  steamSettings: SteamSettings(
    targetTemperature: 150,
    duration: steamDuration,
    flow: 1.0,
  ),
  hotWaterData: HotWaterData(
    targetTemperature: 75,
    duration: 30,
    volume: 50,
    flow: 2.0,
  ),
  rinseData: RinseData(targetTemperature: 90, duration: 5, flow: 2.5),
);

class _LateShotSettingsDe1 extends TestDe1 {
  _LateShotSettingsDe1() : super(deviceId: 'late-de1', name: 'LateDe1');

  int fanThresholdCalls = 0;
  final List<String> calls = [];
  Completer<void>? flushGate;

  @override
  Future<void> setFanThreshhold(int temp) async {
    fanThresholdCalls++;
    calls.add('fan');
  }

  @override
  Future<void> setSteamFlow(double value) async {}

  @override
  Future<void> setHotWaterFlow(double value) async {}

  @override
  Future<void> setFlushFlow(double value) async {
    calls.add('flush');
    final gate = flushGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> setFlushTimeout(double value) async {}

  @override
  Future<void> setFlushTemperature(double value) async {}

  @override
  Future<void> updateShotSettings(De1ShotSettings settings) async {}
}

void main() {
  late DeviceController deviceController;
  late De1Controller de1Controller;
  late _SilentShotSettingsDe1 de1;

  setUp(() async {
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
    de1 = _SilentShotSettingsDe1();
    await de1Controller.connectToDe1(de1);
  });

  tearDown(() async {
    await de1.dispose();
  });

  test('startup defaults still run when shot settings arrive late', () async {
    final controller = De1Controller(controller: deviceController);
    controller.defaultWorkflow = _workflow(steamDuration: 16);
    final lateDe1 = _LateShotSettingsDe1();

    await controller.connectToDe1(lateDe1);
    await Future<void>.delayed(
      ConnectionTimings.initialShotSettingsTimeout +
          const Duration(milliseconds: 200),
    );
    expect(
      lateDe1.fanThresholdCalls,
      0,
      reason: 'the initial shot-settings read must have timed out',
    );

    lateDe1.emitShotSettings(
      De1ShotSettings(
        steamSetting: 0,
        targetSteamTemp: 150,
        targetSteamDuration: 30,
        targetHotWaterTemp: 75,
        targetHotWaterVolume: 50,
        targetHotWaterDuration: 30,
        targetShotVolume: 36,
        groupTemp: 94.0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(lateDe1.fanThresholdCalls, 1);
    await lateDe1.dispose();
  });

  test('deferred startup defaults do not overlap an in-flight write', () async {
    final controller = De1Controller(controller: deviceController);
    controller.defaultWorkflow = _workflow(steamDuration: 16);
    final lateDe1 = _LateShotSettingsDe1();
    lateDe1.flushGate = Completer<void>();

    await controller.connectToDe1(lateDe1);
    await Future<void>.delayed(
      ConnectionTimings.initialShotSettingsTimeout +
          const Duration(milliseconds: 200),
    );
    expect(lateDe1.fanThresholdCalls, 0);

    final pendingWrite = controller.updateFlushSettings(
      RinseData(targetTemperature: 92, duration: 6, flow: 2.5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(lateDe1.calls, ['flush']);

    lateDe1.emitShotSettings(
      De1ShotSettings(
        steamSetting: 0,
        targetSteamTemp: 150,
        targetSteamDuration: 30,
        targetHotWaterTemp: 75,
        targetHotWaterVolume: 50,
        targetHotWaterDuration: 30,
        targetShotVolume: 36,
        groupTemp: 94.0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      lateDe1.fanThresholdCalls,
      0,
      reason: 'late startup defaults must wait for the device write queue',
    );

    lateDe1.flushGate!.complete();
    await pendingWrite;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(lateDe1.fanThresholdCalls, 1);
    expect(lateDe1.calls.first, 'flush');
    expect(lateDe1.calls.indexOf('fan'), greaterThan(0));
    await lateDe1.dispose();
  });

  test(
    'steam write fails fast when the DE1 never reports shot settings',
    () async {
      await expectLater(
        de1Controller.updateWorkflowSettings(
          _workflow(steamDuration: 30),
          _workflow(steamDuration: 16),
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  test(
    'a stalled shot-settings read does not wedge the device write queue',
    () async {
      await expectLater(
        de1Controller.updateWorkflowSettings(
          _workflow(steamDuration: 30),
          _workflow(steamDuration: 16),
        ),
        throwsA(isA<TimeoutException>()),
      );

      await de1Controller
          .updateFlushSettings(
            RinseData(targetTemperature: 92, duration: 6, flow: 2.5),
          )
          .timeout(const Duration(seconds: 5));

      expect(de1.setFlushFlowCalls, 1);
    },
  );
}
