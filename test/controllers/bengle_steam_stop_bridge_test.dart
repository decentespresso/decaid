import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/bengle_steam_stop_bridge.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

/// Recording stub of BengleInterface — only the steam-stop surface is
/// exercised; everything else routes through `noSuchMethod`.
class _RecordingBengle implements BengleInterface {
  @override
  String get deviceId => 'rec-bengle';
  @override
  String get name => 'Bengle-rec';
  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;

  final List<double> stopAtTempWrites = [];
  double _target = 0.0;
  double? blockedTarget;
  Completer<void>? targetEntered;
  Completer<void>? targetRelease;
  int _inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<void> setStopAtTemperatureTarget(double celsius) async {
    stopAtTempWrites.add(celsius);
    _inFlight++;
    maxInFlight = maxInFlight < _inFlight ? _inFlight : maxInFlight;
    try {
      if (celsius == blockedTarget) {
        if (!(targetEntered?.isCompleted ?? true)) {
          targetEntered!.complete();
        }
        await targetRelease!.future;
      }
      _target = celsius;
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<double> getStopAtTemperatureTarget() async => _target;

  @override
  Stream<double> get stopAtTemperatureTarget => Stream.value(_target);

  @override
  Stream<bool> get probeAttached => const Stream.empty();

  @override
  Stream<double> get probeTemperature => const Stream.empty();

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);
  @override
  Stream<ScaleSnapshot> get weightSnapshot => const Stream.empty();
  @override
  Stream<LedStripState> get ledStripState => const Stream.empty();
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}

  @override
  Stream<bool> get ready => Stream<bool>.value(true);

  @override
  Stream<De1ShotSettings> get shotSettings => Stream.value(
    De1ShotSettings(
      steamSetting: 0,
      targetSteamTemp: 150,
      targetSteamDuration: 30,
      targetHotWaterTemp: 75,
      targetHotWaterVolume: 50,
      targetHotWaterDuration: 30,
      targetShotVolume: 36,
      groupTemp: 94,
    ),
  );

  @override
  Future<void> setFanThreshhold(int temp) async {}

  @override
  Future<double> getSteamFlow() async => 0;

  @override
  Future<double> getHotWaterFlow() async => 0;

  @override
  Future<double> getFlushFlow() async => 0;

  @override
  Future<double> getFlushTimeout() async => 0;

  @override
  Future<double> getFlushTemperature() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _debounce = Duration(milliseconds: 20);

void main() {
  late WorkflowController workflow;
  late DeviceController deviceController;
  late De1Controller de1Controller;

  setUp(() async {
    workflow = WorkflowController();
    deviceController = DeviceController([MockDeviceDiscoveryService()]);
    await deviceController.initialize();
    de1Controller = De1Controller(controller: deviceController);
  });

  Future<void> connectBengle(BengleInterface bengle) =>
      de1Controller.connectToDe1(bengle);

  Future<void> pumpDebounce() =>
      Future<void>.delayed(_debounce + const Duration(milliseconds: 30));

  void setStopAtTemp(double value) {
    final updated = workflow.currentWorkflow.steamSettings.copyWith(
      stopAtTemperature: value,
    );
    workflow.updateWorkflow(steamSettings: updated);
  }

  test(
    'stopAtTemperature change writes to connected Bengle after debounce',
    () async {
      final bengle = _RecordingBengle();
      await connectBengle(bengle);

      final bridge = BengleSteamStopBridge(
        workflowController: workflow,
        de1Controller: de1Controller,
        debounce: _debounce,
      );
      await Future<void>.delayed(Duration.zero);
      bengle.stopAtTempWrites.clear();

      setStopAtTemp(65.0);
      await pumpDebounce();

      expect(bengle.stopAtTempWrites, [65.0]);
      await bridge.dispose();
    },
  );

  test('debounce coalesces rapid edits into a single write', () async {
    final bengle = _RecordingBengle();
    await connectBengle(bengle);

    final bridge = BengleSteamStopBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    bengle.stopAtTempWrites.clear();

    for (final t in [50.0, 55.0, 60.0, 65.0]) {
      setStopAtTemp(t);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await pumpDebounce();

    expect(bengle.stopAtTempWrites, [65.0]);
    await bridge.dispose();
  });

  test('latest target waits for an in-flight write', () async {
    final bengle = _RecordingBengle();
    await connectBengle(bengle);

    final bridge = BengleSteamStopBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    bengle.stopAtTempWrites.clear();

    bengle.blockedTarget = 65.0;
    bengle.targetEntered = Completer<void>();
    bengle.targetRelease = Completer<void>();
    setStopAtTemp(65.0);
    await bengle.targetEntered!.future;

    setStopAtTemp(70.0);
    await pumpDebounce();
    expect(bengle.stopAtTempWrites, [65.0]);
    expect(bengle.maxInFlight, 1);

    bengle.targetRelease!.complete();
    await pumpDebounce();
    expect(bengle.stopAtTempWrites, [65.0, 70.0]);
    expect(bengle.maxInFlight, 1);
    await bridge.dispose();
  });

  test('reconnect writes the target to the replacement Bengle', () async {
    final oldBengle = _RecordingBengle();
    await connectBengle(oldBengle);

    final bridge = BengleSteamStopBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    oldBengle.stopAtTempWrites.clear();

    oldBengle.blockedTarget = 65.0;
    oldBengle.targetEntered = Completer<void>();
    oldBengle.targetRelease = Completer<void>();
    setStopAtTemp(65.0);
    await oldBengle.targetEntered!.future.timeout(const Duration(seconds: 2));

    final replacement = _RecordingBengle();
    await connectBengle(replacement);
    await Future<void>.delayed(Duration.zero);
    expect(replacement.stopAtTempWrites, isEmpty);

    oldBengle.targetRelease!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(replacement.stopAtTempWrites, [65.0]);
    expect(oldBengle.maxInFlight, 1);
    await bridge.dispose();
  });

  test('no write when connected machine is not Bengle', () async {
    final de1 = TestDe1();
    await de1Controller.connectToDe1(de1);
    de1.emitShotSettings(
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
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final bridge = BengleSteamStopBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    setStopAtTemp(60.0);
    await pumpDebounce();

    expect(de1.requestedStates, isEmpty);
    de1.dispose();
    await bridge.dispose();
  });

  test('re-applies current target on Bengle (re)connect', () async {
    setStopAtTemp(58.0);

    final bridge = BengleSteamStopBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );

    final bengle = _RecordingBengle();
    await connectBengle(bengle);
    await pumpDebounce();

    expect(bengle.stopAtTempWrites, contains(58.0));
    await bridge.dispose();
  });

  test('dispose stops further writes', () async {
    final bengle = _RecordingBengle();
    await connectBengle(bengle);

    final bridge = BengleSteamStopBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    bengle.stopAtTempWrites.clear();

    await bridge.dispose();
    setStopAtTemp(70.0);
    await pumpDebounce();

    expect(bengle.stopAtTempWrites, isEmpty);
  });
}
