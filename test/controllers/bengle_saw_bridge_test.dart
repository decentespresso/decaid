import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/bengle_saw_bridge.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

import '../helpers/mock_device_discovery_service.dart';
import '../helpers/test_de1.dart';

class _RecordingBengle implements BengleInterface {
  _RecordingBengle();

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

  final List<double> sawWrites = [];
  double _saw = 0.0;
  double? blockedSaw;
  Completer<void>? sawEntered;
  Completer<void>? sawRelease;
  int _inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<void> setStopAtWeightTarget(double grams) async {
    sawWrites.add(grams);
    _inFlight++;
    maxInFlight = maxInFlight < _inFlight ? _inFlight : maxInFlight;
    try {
      if (grams == blockedSaw) {
        if (!(sawEntered?.isCompleted ?? true)) {
          sawEntered!.complete();
        }
        await sawRelease!.future;
      }
      _saw = grams;
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<double> getStopAtWeightTarget() async => _saw;

  @override
  Stream<double> get stopAtWeightTarget => Stream.value(_saw);

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

  Future<void> connectBengle(BengleInterface bengle) async {
    await de1Controller.connectToDe1(bengle);
  }

  Future<void> pumpDebounce() async {
    await Future<void>.delayed(_debounce + const Duration(milliseconds: 30));
  }

  test(
    'targetYield change writes to connected Bengle after debounce',
    () async {
      final bengle = _RecordingBengle();
      await connectBengle(bengle);

      final bridge = BengleSawBridge(
        workflowController: workflow,
        de1Controller: de1Controller,
        debounce: _debounce,
      );
      await Future<void>.delayed(Duration.zero);
      bengle.sawWrites.clear();

      final ctx = workflow.currentWorkflow.context ?? const WorkflowContext();
      workflow.updateWorkflow(context: ctx.copyWith(targetYield: 30.0));
      await pumpDebounce();

      expect(bengle.sawWrites, [30.0]);
      await bridge.dispose();
    },
  );

  test('debounce coalesces rapid edits into a single write', () async {
    final bengle = _RecordingBengle();
    await connectBengle(bengle);

    final bridge = BengleSawBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    bengle.sawWrites.clear();

    final base = workflow.currentWorkflow.context ?? const WorkflowContext();
    for (final y in [29.0, 30.0, 31.0, 32.0]) {
      workflow.updateWorkflow(context: base.copyWith(targetYield: y));
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await pumpDebounce();

    expect(bengle.sawWrites, [32.0]);
    await bridge.dispose();
  });

  test('latest target waits for an in-flight write', () async {
    final bengle = _RecordingBengle();
    await connectBengle(bengle);

    final bridge = BengleSawBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    bengle.sawWrites.clear();

    final base = workflow.currentWorkflow.context ?? const WorkflowContext();
    bengle.blockedSaw = 30.0;
    bengle.sawEntered = Completer<void>();
    bengle.sawRelease = Completer<void>();
    workflow.updateWorkflow(context: base.copyWith(targetYield: 30.0));
    await bengle.sawEntered!.future;

    workflow.updateWorkflow(context: base.copyWith(targetYield: 31.0));
    await pumpDebounce();
    expect(bengle.sawWrites, [30.0]);
    expect(bengle.maxInFlight, 1);

    bengle.sawRelease!.complete();
    await pumpDebounce();
    expect(bengle.sawWrites, [30.0, 31.0]);
    expect(bengle.maxInFlight, 1);
    await bridge.dispose();
  });

  test('reconnect writes the target to the replacement Bengle', () async {
    final oldBengle = _RecordingBengle();
    await connectBengle(oldBengle);

    final bridge = BengleSawBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    oldBengle.sawWrites.clear();

    final base = workflow.currentWorkflow.context ?? const WorkflowContext();
    oldBengle.blockedSaw = 30.0;
    oldBengle.sawEntered = Completer<void>();
    oldBengle.sawRelease = Completer<void>();
    workflow.updateWorkflow(context: base.copyWith(targetYield: 30.0));
    await oldBengle.sawEntered!.future.timeout(const Duration(seconds: 2));

    final replacement = _RecordingBengle();
    await connectBengle(replacement);
    await Future<void>.delayed(Duration.zero);
    expect(replacement.sawWrites, isEmpty);

    oldBengle.sawRelease!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(replacement.sawWrites, [30.0]);
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

    final bridge = BengleSawBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );

    final ctx = workflow.currentWorkflow.context ?? const WorkflowContext();
    workflow.updateWorkflow(context: ctx.copyWith(targetYield: 30.0));
    await pumpDebounce();

    expect(de1.requestedStates, isEmpty);
    de1.dispose();
    await bridge.dispose();
  });

  test('re-applies current target on Bengle (re)connect', () async {
    final ctx = workflow.currentWorkflow.context ?? const WorkflowContext();
    workflow.updateWorkflow(context: ctx.copyWith(targetYield: 28.0));

    final bridge = BengleSawBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );

    final bengle = _RecordingBengle();
    await connectBengle(bengle);
    await pumpDebounce();

    expect(bengle.sawWrites, contains(28.0));
    await bridge.dispose();
  });

  test('dispose stops further writes', () async {
    final bengle = _RecordingBengle();
    await connectBengle(bengle);

    final bridge = BengleSawBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    await bridge.dispose();
    bengle.sawWrites.clear();

    final ctx = workflow.currentWorkflow.context ?? const WorkflowContext();
    workflow.updateWorkflow(context: ctx.copyWith(targetYield: 42.0));
    await pumpDebounce();

    expect(bengle.sawWrites, isEmpty);
  });

  test('zero target is propagated (SAW off)', () async {
    final bengle = _RecordingBengle();
    await connectBengle(bengle);

    final bridge = BengleSawBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    bengle.sawWrites.clear();

    final ctx = workflow.currentWorkflow.context ?? const WorkflowContext();
    workflow.updateWorkflow(context: ctx.copyWith(targetYield: 0.0));
    await pumpDebounce();

    expect(bengle.sawWrites, [0.0]);
    await bridge.dispose();
  });

  test('queue saturation retries the current target', () async {
    await de1Controller.dispose();
    de1Controller = De1Controller(
      controller: deviceController,
      maxPendingDeviceWrites: 0,
    );
    final bengle = _RecordingBengle();
    await connectBengle(bengle);
    final bridge = BengleSawBridge(
      workflowController: workflow,
      de1Controller: de1Controller,
      debounce: _debounce,
    );
    await Future<void>.delayed(Duration.zero);
    bengle.sawWrites.clear();

    final started = Completer<void>();
    final release = Completer<void>();
    final active = de1Controller.runDeviceWrite((_) async {
      started.complete();
      await release.future;
    });
    await started.future;

    final context = workflow.currentWorkflow.context ?? const WorkflowContext();
    workflow.updateWorkflow(context: context.copyWith(targetYield: 42.0));
    await pumpDebounce();
    expect(bengle.sawWrites, isEmpty);

    release.complete();
    await active;
    await pumpDebounce();

    expect(bengle.sawWrites, [42.0]);
    await bridge.dispose();
  });
}
