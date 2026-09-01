import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/shot_sequencer.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/test_de1.dart';
import '../helpers/test_scale.dart';

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

  _TestDe1Controller(this.testDe1)
    : super(controller: DeviceController([_FakeDiscoveryService()]));

  @override
  De1Interface connectedDe1() => testDe1;

  @override
  Stream<De1Interface?> get de1 => BehaviorSubject.seeded(testDe1).stream;

  @override
  Future<void> requestMachineState(MachineState state) {
    return testDe1.requestState(state);
  }

  @override
  Future<bool> requestShotStepSkip(bool Function() stillApplicable) async {
    if (!stillApplicable()) return false;
    await testDe1.requestState(MachineState.skipStep);
    return true;
  }
}

class _TestScaleController extends ScaleController {
  final TestScale testScale;
  final BehaviorSubject<ConnectionState> _connectionState;
  final StreamController<WeightSnapshot> _weight;
  int generation = 0;
  WeightSnapshot? _currentWeight;

  _TestScaleController(this.testScale, {bool replayWeights = true})
    : _connectionState = BehaviorSubject.seeded(ConnectionState.connected),
      _weight = replayWeights
          ? BehaviorSubject<WeightSnapshot>()
          : StreamController<WeightSnapshot>.broadcast();

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  ConnectionState get currentConnectionState => _connectionState.value;

  @override
  int get connectionGeneration => generation;

  @override
  Stream<WeightSnapshot> get weightSnapshot => _weight.stream;

  @override
  WeightSnapshot? get currentWeightSnapshot => _currentWeight;

  @override
  Scale connectedScale() {
    if (_connectionState.value != ConnectionState.connected) {
      throw 'No scale connected';
    }
    return testScale;
  }

  void emitWeight(
    double weight, {
    double weightFlow = 0.0,
    double? controlWeightFlow,
    DateTime? timestamp,
  }) {
    final snapshot = WeightSnapshot(
      timestamp: timestamp ?? DateTime(2026, 1, 15, 8, 0),
      weight: weight,
      weightFlow: weightFlow,
      controlWeightFlow: controlWeightFlow,
      connectionGeneration: generation,
    );
    _currentWeight = snapshot;
    _weight.add(snapshot);
  }

  void simulateDisconnect() {
    generation++;
    _currentWeight = null;
    _connectionState.add(ConnectionState.disconnected);
  }

  void simulateReconnect() {
    generation++;
    _currentWeight = null;
    _connectionState.add(ConnectionState.connected);
  }

  void simulateHandoff() {
    generation++;
    _currentWeight = null;
  }

  void announceConnected() {
    _connectionState.add(ConnectionState.connected);
  }

  @override
  void dispose() {
    _connectionState.close();
    _weight.close();
    super.dispose();
  }
}

class _NullStorageService implements StorageService {
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

Profile _simpleProfile() {
  return Profile(
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
}

Profile _profileWithSteps(List<ProfileStep> steps) {
  return Profile(
    version: '2',
    title: 'Test Profile',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    targetVolumeCountStart: 0,
    tankTemperature: 0,
    targetWeight: 200,
    steps: steps,
  );
}

ProfileStepPressure _pressureStep({
  required String name,
  double? weight,
  StepExitCondition? exit,
}) {
  return ProfileStepPressure(
    name: name,
    transition: TransitionType.fast,
    exit: exit,
    volume: 0,
    seconds: 30,
    weight: weight,
    temperature: 93,
    sensor: TemperatureSensor.coffee,
    pressure: 9,
  );
}

ProfileStepFlow _flowStep({
  required String name,
  double? weight,
  StepExitCondition? exit,
}) {
  return ProfileStepFlow(
    name: name,
    transition: TransitionType.fast,
    exit: exit,
    volume: 0,
    seconds: 30,
    weight: weight,
    temperature: 93,
    sensor: TemperatureSensor.coffee,
    flow: 4,
  );
}

void main() {
  test('step weight exit retries after governor saturation clears', () async {
    final testDe1 = TestDe1();
    final devices = DeviceController([_FakeDiscoveryService()]);
    await devices.initialize();
    final de1Controller = De1Controller(
      controller: devices,
      maxPendingDeviceWrites: 0,
    );
    await de1Controller.connectToDe1(testDe1);
    testDe1.emitShotSettings(
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
    await de1Controller.initSettled.firstWhere(
      (generation) => generation != null,
    );
    addTearDown(de1Controller.dispose);

    final testScale = TestScale();
    final scaleController = _TestScaleController(testScale);
    addTearDown(() {
      scaleController.dispose();
      testScale.dispose();
    });
    final persistenceController = PersistenceController(
      storageService: _NullStorageService(),
    );
    addTearDown(persistenceController.dispose);
    final profile = _profileWithSteps([
      _pressureStep(name: 'retry', weight: 10),
    ]);
    scaleController.emitWeight(0);
    final sequencer = ShotSequencer(
      scaleController: scaleController,
      de1controller: de1Controller,
      persistenceController: persistenceController,
      targetProfile: profile,
      targetYield: 200,
      bypassSAW: false,
      blockOnNoScale: false,
      weightFlowMultiplier: 0,
      volumeFlowMultiplier: 0,
      stepExitArbiterEnabled: true,
    );
    addTearDown(sequencer.dispose);

    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.preparingForShot,
    );
    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.pouring,
    );

    final activeStarted = Completer<void>();
    final activeRelease = Completer<void>();
    final active = de1Controller.runDeviceWrite((_) async {
      activeStarted.complete();
      await activeRelease.future;
    });
    await activeStarted.future;

    scaleController.emitWeight(12);
    testDe1.emitSnapshot(
      testDe1.snapshotSubject.value.copyWith(profileFrame: 0),
    );
    await Future<void>.delayed(Duration.zero);
    expect(testDe1.requestedStates, isNot(contains(MachineState.skipStep)));

    activeRelease.complete();
    await active;
    final skipped = sequencer.decisions.firstWhere(
      (decision) => decision.reason == ShotDecisionReason.profileSkip,
    );
    testDe1.emitSnapshot(
      testDe1.snapshotSubject.value.copyWith(profileFrame: 0),
    );
    await skipped;

    expect(testDe1.requestedStates, contains(MachineState.skipStep));
    expect(sequencer.skippedSteps, [0]);
  });

  test('admitted step skip is dropped after the frame advances', () async {
    final testDe1 = TestDe1();
    final devices = DeviceController([_FakeDiscoveryService()]);
    await devices.initialize();
    final de1Controller = De1Controller(
      controller: devices,
      maxPendingDeviceWrites: 1,
    );
    await de1Controller.connectToDe1(testDe1);
    testDe1.emitShotSettings(
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
    await de1Controller.initSettled.firstWhere(
      (generation) => generation != null,
    );
    addTearDown(de1Controller.dispose);

    final testScale = TestScale();
    final scaleController = _TestScaleController(testScale);
    addTearDown(() {
      scaleController.dispose();
      testScale.dispose();
    });
    final persistenceController = PersistenceController(
      storageService: _NullStorageService(),
    );
    addTearDown(persistenceController.dispose);
    scaleController.emitWeight(0);
    final sequencer = ShotSequencer(
      scaleController: scaleController,
      de1controller: de1Controller,
      persistenceController: persistenceController,
      targetProfile: _profileWithSteps([
        _pressureStep(name: 'first', weight: 10),
        _pressureStep(name: 'second', weight: 20),
      ]),
      targetYield: 200,
      bypassSAW: false,
      blockOnNoScale: false,
      weightFlowMultiplier: 0,
      volumeFlowMultiplier: 0,
      stepExitArbiterEnabled: true,
    );
    addTearDown(sequencer.dispose);
    final decisions = <ShotDecision>[];
    final decisionSubscription = sequencer.decisions.listen(decisions.add);
    addTearDown(decisionSubscription.cancel);
    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.preparingForShot,
    );
    testDe1.emitStateAndSubstate(
      MachineState.espresso,
      MachineSubstate.pouring,
    );

    final activeStarted = Completer<void>();
    final activeRelease = Completer<void>();
    final active = de1Controller.runDeviceWrite((_) async {
      activeStarted.complete();
      await activeRelease.future;
    });
    await activeStarted.future;

    scaleController.emitWeight(12);
    testDe1.emitSnapshot(
      testDe1.snapshotSubject.value.copyWith(profileFrame: 0),
    );
    await Future<void>.delayed(Duration.zero);
    expect(de1Controller.pendingDeviceWriteCount, 1);

    testDe1.emitSnapshot(
      testDe1.snapshotSubject.value.copyWith(profileFrame: 1),
    );
    await Future<void>.delayed(Duration.zero);
    activeRelease.complete();
    await active;
    await Future<void>.delayed(Duration.zero);

    expect(testDe1.requestedStates, isNot(contains(MachineState.skipStep)));
    expect(sequencer.skippedSteps, isEmpty);
    expect(
      decisions.where(
        (decision) => decision.reason == ShotDecisionReason.profileSkip,
      ),
      isEmpty,
    );
  });

  group('ShotSequencer — scale disconnect during shot', () {
    late TestDe1 testDe1;
    late TestScale testScale;
    late _TestDe1Controller de1Controller;
    late _TestScaleController scaleController;
    late PersistenceController persistenceController;
    late Profile profile;

    setUp(() {
      testDe1 = TestDe1();
      testScale = TestScale();
      de1Controller = _TestDe1Controller(testDe1);
      scaleController = _TestScaleController(testScale);
      persistenceController = PersistenceController(
        storageService: _NullStorageService(),
      );
      profile = _simpleProfile();
    });

    tearDown(() {
      testDe1.dispose();
      testScale.dispose();
      scaleController.dispose();
      persistenceController.dispose();
    });

    void driveToPouring(ShotSequencer shotSequencer) {
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.preparingForShot,
      );

      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouring,
      );
    }

    void emitPouringFrame(int profileFrame) {
      final current = testDe1.snapshotSubject.value;
      testDe1.emitSnapshot(
        current.copyWith(
          state: const MachineStateSnapshot(
            state: MachineState.espresso,
            substate: MachineSubstate.pouring,
          ),
          profileFrame: profileFrame,
        ),
      );
    }

    void emitPouringFrameWithPressure(int profileFrame, double pressure) {
      final current = testDe1.snapshotSubject.value;
      testDe1.emitSnapshot(
        current.copyWith(
          state: const MachineStateSnapshot(
            state: MachineState.espresso,
            substate: MachineSubstate.pouring,
          ),
          profileFrame: profileFrame,
          pressure: pressure,
        ),
      );
    }

    void emitPouringFrameWithFlow(int profileFrame, double flow) {
      final current = testDe1.snapshotSubject.value;
      testDe1.emitSnapshot(
        current.copyWith(
          state: const MachineStateSnapshot(
            state: MachineState.espresso,
            substate: MachineSubstate.pouring,
          ),
          profileFrame: profileFrame,
          flow: flow,
        ),
      );
    }

    test(
      'fresh pre-subscription scale sample remains active for replayed start',
      () {
        fakeAsync((async) {
          final nonReplayingScale = _TestScaleController(
            testScale,
            replayWeights: false,
          );
          nonReplayingScale.emitWeight(0);
          testDe1.emitStateAndSubstate(
            MachineState.espresso,
            MachineSubstate.preparingForShot,
          );
          final shotSequencer = ShotSequencer(
            scaleController: nonReplayingScale,
            de1controller: de1Controller,
            persistenceController: persistenceController,
            targetProfile: profile,
            targetYield: 36.0,
            bypassSAW: false,
            blockOnNoScale: false,
            weightFlowMultiplier: 0.0,
            volumeFlowMultiplier: 0.0,
            stepExitArbiterEnabled: true,
          );
          final snapshots = <ShotSnapshot>[];
          shotSequencer.shotData.listen(snapshots.add);

          async.elapse(const Duration(milliseconds: 10));
          expect(shotSequencer.currentState, ShotState.preheating);

          testDe1.emitStateAndSubstate(
            MachineState.espresso,
            MachineSubstate.pouring,
          );
          nonReplayingScale.emitWeight(40);
          testDe1.emitStateAndSubstate(
            MachineState.espresso,
            MachineSubstate.pouring,
          );
          async.elapse(const Duration(milliseconds: 10));

          expect(testDe1.requestedStates, contains(MachineState.idle));
          expect(snapshots.any((snapshot) => snapshot.scale != null), isTrue);

          shotSequencer.dispose();
          nonReplayingScale.dispose();
        });
      },
    );

    test('scale handoff during a shot stays scaleless', () {
      fakeAsync((async) {
        scaleController.emitWeight(0);
        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );
        final snapshots = <ShotSnapshot>[];
        shotSequencer.shotData.listen(snapshots.add);

        driveToPouring(shotSequencer);
        async.elapse(const Duration(milliseconds: 10));
        scaleController.simulateHandoff();
        scaleController.announceConnected();
        scaleController.emitWeight(40);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(const Duration(milliseconds: 10));

        expect(shotSequencer.scaleLost, isTrue);
        expect(testDe1.requestedStates, isEmpty);
        expect(snapshots.last.scale, isNull);

        shotSequencer.dispose();
      });
    });

    test('continues scaleless when the first scale sample arrives late', () {
      fakeAsync((async) {
        final nonReplayingScale = _TestScaleController(
          testScale,
          replayWeights: false,
        );
        final shotSequencer = ShotSequencer(
          scaleController: nonReplayingScale,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );
        final snapshots = <ShotSnapshot>[];
        shotSequencer.shotData.listen(snapshots.add);

        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.preparingForShot,
        );
        nonReplayingScale.emitWeight(40);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        nonReplayingScale.emitWeight(40);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(const Duration(milliseconds: 10));

        expect(shotSequencer.currentState, ShotState.pouring);
        expect(testDe1.requestedStates, isEmpty);
        expect(snapshots.every((snapshot) => snapshot.scale == null), isTrue);

        shotSequencer.dispose();
        nonReplayingScale.dispose();
      });
    });

    test('does not associate a stale scale sample', () {
      fakeAsync((async) {
        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );
        scaleController.emitWeight(
          0,
          timestamp: DateTime(2026, 1, 15, 7, 59, 57),
        );

        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.preparingForShot,
        );
        async.elapse(const Duration(milliseconds: 10));

        expect(shotSequencer.currentState, ShotState.preheating);
        expect(testScale.tareCallCount, 0);

        shotSequencer.dispose();
      });
    });

    test('does not associate a sample from an older scale connection', () {
      fakeAsync((async) {
        scaleController.emitWeight(0);
        scaleController.simulateDisconnect();
        scaleController.simulateReconnect();
        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.preparingForShot,
        );
        async.elapse(const Duration(milliseconds: 10));

        expect(shotSequencer.currentState, ShotState.preheating);
        expect(testScale.tareCallCount, 0);

        shotSequencer.dispose();
      });
    });

    test('disables SAW when scale disconnects during pouring', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.simulateDisconnect();
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(40.0);

        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          isEmpty,
          reason:
              'SAW should not fire when scale is disconnected, but it did — '
              'the controller is using stale weight data',
        );

        shotSequencer.dispose();
      });
    });

    test('SAW projects weight with control flow', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);
        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 1.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        scaleController.emitWeight(
          35.0,
          weightFlow: 0.0,
          controlWeightFlow: 2.0,
        );
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        expect(testDe1.requestedStates, contains(MachineState.idle));
        shotSequencer.dispose();
      });
    });

    test(
      'does not crash when scale disconnects and timer stop is attempted',
      () {
        fakeAsync((async) {
          scaleController.emitWeight(0.0);

          final shotSequencer = ShotSequencer(
            scaleController: scaleController,
            de1controller: de1Controller,
            persistenceController: persistenceController,
            targetProfile: profile,
            targetYield: 36.0,
            bypassSAW: false,
            blockOnNoScale: false,
            weightFlowMultiplier: 0.0,
            volumeFlowMultiplier: 0.0,
            stepExitArbiterEnabled: true,
          );

          async.elapse(Duration(milliseconds: 10));
          driveToPouring(shotSequencer);
          async.elapse(Duration(milliseconds: 10));

          scaleController.simulateDisconnect();
          async.elapse(Duration(milliseconds: 10));

          testDe1.emitStateAndSubstate(
            MachineState.espresso,
            MachineSubstate.pouringDone,
          );
          async.elapse(Duration(milliseconds: 10));

          expect(
            () {
              testDe1.emitStateAndSubstate(
                MachineState.espresso,
                MachineSubstate.pouringDone,
              );
              async.elapse(Duration(milliseconds: 10));
            },
            returnsNormally,
            reason:
                'Should not crash when scale disconnects and shot ends — '
                'connectedScale() throws when scale is gone',
          );

          shotSequencer.dispose();
        });
      },
    );

    test('SAW still works normally when scale stays connected', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(40.0);

        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          contains(MachineState.idle),
          reason:
              'SAW should fire when scale is connected and weight exceeds target',
        );

        shotSequencer.dispose();
      });
    });

    test('mixed step fires skipStep when firmware exit is far', () {
      fakeAsync((async) {
        profile = _profileWithSteps([
          _pressureStep(
            name: 'mixed-far',
            weight: 10,
            exit: const StepExitCondition(
              type: ExitType.pressure,
              condition: ExitCondition.over,
              value: 9,
            ),
          ),
        ]);
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 200.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrame(0);
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          contains(MachineState.skipStep),
          reason:
              'Firmware exit is far from threshold (pressure 0, exit at 9) — '
              'weight exit should fire immediately.',
        );

        shotSequencer.dispose();
      });
    });

    test('mixed step defers skipStep when firmware exit is near', () {
      fakeAsync((async) {
        profile = _profileWithSteps([
          _pressureStep(
            name: 'mixed-near',
            weight: 10,
            exit: const StepExitCondition(
              type: ExitType.pressure,
              condition: ExitCondition.over,
              value: 5,
            ),
          ),
        ]);
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 200.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrameWithPressure(0, 4.0);
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          isNot(contains(MachineState.skipStep)),
          reason:
              'Firmware exit is near (pressure 4.0, exit at 5.0) — '
              'should defer to avoid racing firmware.',
        );

        scaleController.emitWeight(12.0);
        emitPouringFrameWithPressure(0, 4.2);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrameWithPressure(0, 4.4);
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          contains(MachineState.skipStep),
          reason:
              'After max deferral (3 frames), weight exit fires regardless.',
        );

        shotSequencer.dispose();
      });
    });

    test('mixed step skips deferral when firmware exit has value 0', () {
      fakeAsync((async) {
        profile = _profileWithSteps([
          _pressureStep(
            name: 'noop-exit',
            weight: 10,
            exit: const StepExitCondition(
              type: ExitType.pressure,
              condition: ExitCondition.over,
              value: 0,
            ),
          ),
        ]);
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 200.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrame(0);
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          contains(MachineState.skipStep),
          reason: 'Exit value 0 is a no-op — weight fires immediately.',
        );

        shotSequencer.dispose();
      });
    });

    test('pure weight step still sends skipStep', () {
      fakeAsync((async) {
        profile = _profileWithSteps([
          _pressureStep(name: 'weight-only', weight: 10),
        ]);
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 200.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrame(0);
        async.elapse(Duration(milliseconds: 10));

        expect(testDe1.requestedStates, contains(MachineState.skipStep));

        shotSequencer.dispose();
      });
    });

    test('mixed-exit deferral is frame-local', () {
      fakeAsync((async) {
        profile = _profileWithSteps([
          _pressureStep(
            name: 'near-exit',
            weight: 10,
            exit: const StepExitCondition(
              type: ExitType.pressure,
              condition: ExitCondition.over,
              value: 5,
            ),
          ),
          _pressureStep(name: 'weight-owned', weight: 20),
        ]);
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 200.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrameWithPressure(0, 4.0);
        async.elapse(Duration(milliseconds: 10));

        expect(testDe1.requestedStates, isNot(contains(MachineState.skipStep)));

        scaleController.emitWeight(22.0);
        emitPouringFrame(1);
        async.elapse(Duration(milliseconds: 10));

        expect(testDe1.requestedStates, contains(MachineState.skipStep));

        shotSequencer.dispose();
      });
    });

    test('firmware frame advance cancels pending deferral', () {
      fakeAsync((async) {
        profile = _profileWithSteps([
          _pressureStep(
            name: 'near-exit',
            weight: 10,
            exit: const StepExitCondition(
              type: ExitType.pressure,
              condition: ExitCondition.over,
              value: 5,
            ),
          ),
          _pressureStep(name: 'next-step', weight: 50),
        ]);
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 200.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrameWithPressure(0, 4.0);
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          isNot(contains(MachineState.skipStep)),
          reason: 'Deferred on frame 0',
        );

        scaleController.emitWeight(12.0);
        emitPouringFrame(1);
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          isNot(contains(MachineState.skipStep)),
          reason:
              'Frame 0 deferral cancelled by firmware advance. '
              'Frame 1 weight not yet reached.',
        );

        shotSequencer.dispose();
      });
    });

    test('mixed flow-under step defers when near threshold', () {
      fakeAsync((async) {
        profile = _profileWithSteps([
          _flowStep(
            name: 'flow-near',
            weight: 10,
            exit: const StepExitCondition(
              type: ExitType.flow,
              condition: ExitCondition.under,
              value: 2.0,
            ),
          ),
        ]);
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 200.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrameWithFlow(0, 2.5);
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          isNot(contains(MachineState.skipStep)),
          reason: 'Flow near under-2.0 exit → defer to avoid racing firmware.',
        );

        scaleController.emitWeight(12.0);
        emitPouringFrameWithFlow(0, 2.3);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrameWithFlow(0, 2.1);
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          contains(MachineState.skipStep),
          reason: 'Max deferral → fire.',
        );

        shotSequencer.dispose();
      });
    });

    test('trusted final yield ignores cup removal during drip window', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(36.0, weightFlow: 0.4);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(36.5, weightFlow: 0.3);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(
          2.0,
          weightFlow: 0.0,
          controlWeightFlow: -20.0,
        );
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        expect(shotSequencer.trustedFinalYield, 36.5);

        shotSequencer.dispose();
      });
    });

    test('an upward touch spike locks the yield at the pre-spike value', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(36.0, weightFlow: 0.4);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(36.3, weightFlow: 0.3);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(45.0, weightFlow: 12.0);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        expect(shotSequencer.trustedFinalYield, 36.3);

        shotSequencer.dispose();
      });
    });

    test('captures a turbo catch-up beyond the old gram and flow caps', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 30.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(30.0, weightFlow: 8.0);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        for (final s in [
          [34.0, 6.0],
          [37.0, 4.0],
          [38.0, 1.0],
        ]) {
          scaleController.emitWeight(s[0], weightFlow: s[1]);
          testDe1.emitStateAndSubstate(
            MachineState.espresso,
            MachineSubstate.pouringDone,
          );
          async.elapse(Duration(milliseconds: 10));
        }

        for (var i = 0; i < 3; i++) {
          scaleController.emitWeight(38.1, weightFlow: 0.1);
          testDe1.emitStateAndSubstate(
            MachineState.espresso,
            MachineSubstate.pouringDone,
          );
          async.elapse(Duration(milliseconds: 10));
        }

        expect(shotSequencer.trustedFinalYield, 38.1);

        shotSequencer.dispose();
      });
    });

    test('settling locks the yield and finishes the shot', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 100.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        final states = <ShotState>[];
        shotSequencer.state.listen(states.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(36.0, weightFlow: 0.3);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        for (var i = 0; i < 10; i++) {
          scaleController.emitWeight(36.1, weightFlow: 0.1);
          testDe1.emitStateAndSubstate(
            MachineState.espresso,
            MachineSubstate.pouringDone,
          );
          async.elapse(Duration(milliseconds: 10));
        }

        expect(shotSequencer.trustedFinalYield, 36.1);
        expect(
          states,
          contains(ShotState.finished),
          reason:
              'settling finalizes the shot without waiting for the backstop',
        );

        shotSequencer.dispose();
      });
    });

    test('recorded trace stops at the machine-reported shot end; drips only '
        'refine the yield', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 100.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        final recorded = <ShotSnapshot>[];
        shotSequencer.shotData.listen(recorded.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(30.0, weightFlow: 1.5);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(35.5, weightFlow: 0.8);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(36.0, weightFlow: 0.3);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(36.4, weightFlow: 0.2);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        expect(recorded.map((s) => s.scale?.weight).toList(), [
          0.0,
          0.0,
          30.0,
          35.5,
        ]);
        expect(
          recorded.last.machine.state.substate,
          MachineSubstate.pouring,
          reason: 'trace ends on the last actively-pouring sample',
        );
        expect(shotSequencer.trustedFinalYield, 36.4);

        shotSequencer.dispose();
      });
    });

    test('suppresses weight and flow to 0 until the pour-time tare', () {
      fakeAsync((async) {
        scaleController.emitWeight(80.0, weightFlow: 1.2);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        final recorded = <ShotSnapshot>[];
        shotSequencer.shotData.listen(recorded.add);

        async.elapse(Duration(milliseconds: 10));

        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.preparingForShot,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(80.1, weightFlow: 0.4);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.preparingForShot,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(0.0, weightFlow: 0.0);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(18.0, weightFlow: 2.0);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        expect(
          recorded.map((s) => s.scale?.weight).toList(),
          [0.0, 0.0, 0.0, 18.0],
          reason: 'pre-tare frames are 0; real weight only after the pour tare',
        );
        expect(
          recorded.map((s) => s.scale?.weightFlow).toList(),
          [0.0, 0.0, 0.0, 2.0],
          reason: 'flow off the un-tared cup must not leak either',
        );

        shotSequencer.dispose();
      });
    });

    test('non-scale shot finishes immediately, with no settling window', () {
      fakeAsync((async) {
        scaleController.simulateDisconnect();

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        final states = <ShotState>[];
        shotSequencer.state.listen(states.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 50));

        expect(
          states,
          contains(ShotState.finished),
          reason: 'no-scale shot finishes without waiting for drips',
        );
        expect(
          states,
          isNot(contains(ShotState.stopping)),
          reason: 'no-scale shot never enters the drip-settling window',
        );
        expect(shotSequencer.trustedFinalYield, isNull);

        shotSequencer.dispose();
      });
    });
  });

  group('ShotSequencer — blockOnNoScale', () {
    late TestDe1 testDe1;
    late TestScale testScale;
    late _TestDe1Controller de1Controller;
    late _TestScaleController scaleController;
    late PersistenceController persistenceController;
    late Profile profile;

    setUp(() {
      testDe1 = TestDe1();
      testScale = TestScale();
      de1Controller = _TestDe1Controller(testDe1);
      scaleController = _TestScaleController(testScale);
      persistenceController = PersistenceController(
        storageService: _NullStorageService(),
      );
      profile = _simpleProfile();
    });

    tearDown(() {
      testDe1.dispose();
      testScale.dispose();
      scaleController.dispose();
      persistenceController.dispose();
    });

    test(
      'aborts shot and emits noScale decision when no scale connected at start',
      () {
        fakeAsync((async) {
          scaleController.simulateDisconnect();

          final shotSequencer = ShotSequencer(
            scaleController: scaleController,
            de1controller: de1Controller,
            persistenceController: persistenceController,
            targetProfile: profile,
            targetYield: 36.0,
            bypassSAW: false,
            blockOnNoScale: true,
            weightFlowMultiplier: 0.0,
            volumeFlowMultiplier: 0.0,
            stepExitArbiterEnabled: true,
          );

          final decisions = <ShotDecision>[];
          final snapshots = <ShotSnapshot>[];
          shotSequencer.decisions.listen(decisions.add);
          shotSequencer.shotData.listen(snapshots.add);

          async.elapse(Duration(milliseconds: 10));

          testDe1.emitStateAndSubstate(
            MachineState.espresso,
            MachineSubstate.pouring,
          );
          async.elapse(Duration(milliseconds: 10));

          expect(
            testDe1.requestedStates,
            contains(MachineState.idle),
            reason: 'shot should be aborted back to idle',
          );
          expect(decisions, hasLength(1));
          expect(decisions.single.reason, ShotDecisionReason.noScale);
          expect(
            snapshots,
            isEmpty,
            reason: 'no monitoring should be wired when the shot is blocked',
          );

          shotSequencer.dispose();
        });
      },
    );

    test(
      'does not block when blockOnNoScale is false and no scale connected',
      () {
        fakeAsync((async) {
          scaleController.simulateDisconnect();

          final shotSequencer = ShotSequencer(
            scaleController: scaleController,
            de1controller: de1Controller,
            persistenceController: persistenceController,
            targetProfile: profile,
            targetYield: 36.0,
            bypassSAW: false,
            blockOnNoScale: false,
            weightFlowMultiplier: 0.0,
            volumeFlowMultiplier: 0.0,
            stepExitArbiterEnabled: true,
          );

          final decisions = <ShotDecision>[];
          shotSequencer.decisions.listen(decisions.add);

          async.elapse(Duration(milliseconds: 10));

          expect(testDe1.requestedStates, isEmpty);
          expect(decisions, isEmpty);

          shotSequencer.dispose();
        });
      },
    );
  });

  group('ShotSequencer — step exit arbiter disabled', () {
    late TestDe1 testDe1;
    late TestScale testScale;
    late _TestDe1Controller de1Controller;
    late _TestScaleController scaleController;
    late PersistenceController persistenceController;
    late Profile profile;

    setUp(() {
      testDe1 = TestDe1();
      testScale = TestScale();
      de1Controller = _TestDe1Controller(testDe1);
      scaleController = _TestScaleController(testScale);
      persistenceController = PersistenceController(
        storageService: _NullStorageService(),
      );
      profile = _profileWithSteps([
        _pressureStep(
          name: 'mixed-near',
          weight: 10,
          exit: const StepExitCondition(
            type: ExitType.pressure,
            condition: ExitCondition.over,
            value: 5,
          ),
        ),
      ]);
    });

    tearDown(() {
      testDe1.dispose();
      testScale.dispose();
      scaleController.dispose();
      persistenceController.dispose();
    });

    void driveToPouring(ShotSequencer shotSequencer) {
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.preparingForShot,
      );
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouring,
      );
    }

    void emitPouringFrameWithPressure(int profileFrame, double pressure) {
      final current = testDe1.snapshotSubject.value;
      testDe1.emitSnapshot(
        current.copyWith(
          state: const MachineStateSnapshot(
            state: MachineState.espresso,
            substate: MachineSubstate.pouring,
          ),
          profileFrame: profileFrame,
          pressure: pressure,
        ),
      );
    }

    test('fires skipStep immediately even when firmware exit is near', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);

        final shotSequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: profile,
          targetYield: 200.0,
          bypassSAW: false,
          blockOnNoScale: false,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: false,
        );

        async.elapse(Duration(milliseconds: 10));
        driveToPouring(shotSequencer);
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrameWithPressure(0, 4.0);
        async.elapse(Duration(milliseconds: 10));

        expect(
          testDe1.requestedStates,
          contains(MachineState.skipStep),
          reason:
              'With stepExitArbiter disabled, weight exit should fire '
              'immediately even when near firmware threshold.',
        );

        shotSequencer.dispose();
      });
    });
  });

  group('ShotSequencer — decision stream', () {
    late TestDe1 testDe1;
    late TestScale testScale;
    late _TestDe1Controller de1Controller;
    late _TestScaleController scaleController;
    late PersistenceController persistenceController;

    setUp(() {
      testDe1 = TestDe1();
      testScale = TestScale();
      de1Controller = _TestDe1Controller(testDe1);
      scaleController = _TestScaleController(testScale);
      persistenceController = PersistenceController(
        storageService: _NullStorageService(),
      );
    });

    tearDown(() {
      testDe1.dispose();
      testScale.dispose();
      scaleController.dispose();
      persistenceController.dispose();
    });

    ShotSequencer makeSequencer({
      Profile? profile,
      double targetYield = 36.0,
      double volumeFlowMultiplier = 0.0,
    }) {
      return ShotSequencer(
        scaleController: scaleController,
        de1controller: de1Controller,
        persistenceController: persistenceController,
        targetProfile: profile ?? _simpleProfile(),
        targetYield: targetYield,
        bypassSAW: false,
        blockOnNoScale: false,
        weightFlowMultiplier: 0.0,
        volumeFlowMultiplier: volumeFlowMultiplier,
        stepExitArbiterEnabled: true,
      );
    }

    void driveToPouring() {
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.preparingForShot,
      );
      testDe1.emitStateAndSubstate(
        MachineState.espresso,
        MachineSubstate.pouring,
      );
    }

    void emitPouringFrame(int profileFrame, {double flow = 0}) {
      final current = testDe1.snapshotSubject.value;
      testDe1.emitSnapshot(
        current.copyWith(
          state: const MachineStateSnapshot(
            state: MachineState.espresso,
            substate: MachineSubstate.pouring,
          ),
          profileFrame: profileFrame,
          flow: flow,
        ),
      );
    }

    test('target weight stop emits stop/targetWeight and latches it as the '
        'final stop reason', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer();
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(40.0);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        final stop = decisions.singleWhere(
          (d) => d.reason == ShotDecisionReason.targetWeight,
        );
        expect(stop.kind, ShotDecisionKind.stop);
        expect(stop.data?['targetYield'], 36.0);
        expect(sequencer.finalStopReason, ShotDecisionReason.targetWeight);
        expect(testDe1.requestedStates, contains(MachineState.idle));

        sequencer.dispose();
      });
    });

    test('target volume stop emits stop/targetVolume when no scale weighs '
        'the shot', () {
      fakeAsync((async) {
        scaleController.simulateDisconnect();
        final profile = Profile(
          version: '2',
          title: 'Volume Profile',
          notes: '',
          author: 'test',
          beverageType: BeverageType.espresso,
          targetVolumeCountStart: 0,
          tankTemperature: 0,
          targetWeight: 0,
          targetVolume: 50,
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
        final sequencer = makeSequencer(
          profile: profile,
          volumeFlowMultiplier: 1.0,
        );
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        emitPouringFrame(0, flow: 60);
        async.elapse(Duration(milliseconds: 10));

        final stop = decisions.singleWhere(
          (d) => d.reason == ShotDecisionReason.targetVolume,
        );
        expect(stop.kind, ShotDecisionKind.stop);
        expect(sequencer.finalStopReason, ShotDecisionReason.targetVolume);
        expect(testDe1.requestedStates, contains(MachineState.idle));

        sequencer.dispose();
      });
    });

    test('machine-reported end without any recorded intent emits '
        'stop/machineEnded', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer();
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        final stop = decisions.singleWhere(
          (d) => d.kind == ShotDecisionKind.stop,
        );
        expect(stop.reason, ShotDecisionReason.machineEnded);
        expect(sequencer.finalStopReason, ShotDecisionReason.machineEnded);

        sequencer.dispose();
      });
    });

    test('a recent REST stop intent attributes the stop to apiStop', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer();
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        de1Controller.recordStopIntent(ShotDecisionReason.apiStop);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        final stop = decisions.singleWhere(
          (d) => d.kind == ShotDecisionKind.stop,
        );
        expect(stop.reason, ShotDecisionReason.apiStop);
        expect(sequencer.finalStopReason, ShotDecisionReason.apiStop);

        sequencer.dispose();
      });
    });

    test('a recent app-UI stop intent attributes the stop to appStop', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer();
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        de1Controller.recordStopIntent(ShotDecisionReason.appStop);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        expect(
          decisions.singleWhere((d) => d.kind == ShotDecisionKind.stop).reason,
          ShotDecisionReason.appStop,
        );

        sequencer.dispose();
      });
    });

    test('a stale stop intent falls back to machineEnded', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer();
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        de1Controller.recordStopIntent(ShotDecisionReason.apiStop);
        async.elapse(Duration(seconds: 6));

        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        expect(
          decisions.singleWhere((d) => d.kind == ShotDecisionKind.stop).reason,
          ShotDecisionReason.machineEnded,
          reason:
              'an intent recorded long before the shot end must not be '
              'attributed to it',
        );

        sequencer.dispose();
      });
    });

    test('app-issued step weight exit emits advance/profileSkip and no '
        'profileAdvance for the same frame', () {
      fakeAsync((async) {
        final profile = _profileWithSteps([
          _pressureStep(name: 'first', weight: 10),
          _pressureStep(name: 'second'),
        ]);
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer(profile: profile, targetYield: 200);
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(12.0);
        emitPouringFrame(0);
        async.elapse(Duration(milliseconds: 10));

        final skip = decisions.singleWhere(
          (d) => d.reason == ShotDecisionReason.profileSkip,
        );
        expect(skip.kind, ShotDecisionKind.advance);
        expect(skip.data?['frame'], 0);
        expect(testDe1.requestedStates, contains(MachineState.skipStep));

        scaleController.emitWeight(12.0);
        emitPouringFrame(1);
        async.elapse(Duration(milliseconds: 10));

        expect(
          decisions.where((d) => d.reason == ShotDecisionReason.profileAdvance),
          isEmpty,
          reason:
              'an app-skipped frame must not double-report as a '
              'firmware-natural advance',
        );

        sequencer.dispose();
      });
    });

    test('firmware-natural frame advance emits advance/profileAdvance', () {
      fakeAsync((async) {
        final profile = _profileWithSteps([
          _pressureStep(name: 'first'),
          _pressureStep(name: 'second'),
        ]);
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer(profile: profile, targetYield: 200);
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        emitPouringFrame(0);
        async.elapse(Duration(milliseconds: 10));
        emitPouringFrame(1);
        async.elapse(Duration(milliseconds: 10));

        final advance = decisions.singleWhere(
          (d) => d.reason == ShotDecisionReason.profileAdvance,
        );
        expect(advance.kind, ShotDecisionKind.advance);
        expect(advance.data?['fromFrame'], 0);
        expect(advance.data?['toFrame'], 1);

        sequencer.dispose();
      });
    });

    test('a multi-frame jump reports one advance per vacated frame', () {
      fakeAsync((async) {
        final profile = _profileWithSteps([
          _pressureStep(name: 'a'),
          _pressureStep(name: 'b'),
          _pressureStep(name: 'c'),
        ]);
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer(profile: profile, targetYield: 200);
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        emitPouringFrame(0);
        async.elapse(Duration(milliseconds: 10));
        emitPouringFrame(2);
        async.elapse(Duration(milliseconds: 10));

        final advances = decisions
            .where((d) => d.reason == ShotDecisionReason.profileAdvance)
            .toList();
        expect(advances, hasLength(2));
        expect(advances[0].data?['fromFrame'], 0);
        expect(advances[1].data?['fromFrame'], 1);

        emitPouringFrame(1);
        async.elapse(Duration(milliseconds: 10));
        expect(
          decisions.where((d) => d.reason == ShotDecisionReason.profileAdvance),
          hasLength(2),
        );

        sequencer.dispose();
      });
    });

    test(
      'machine error mid-shot emits terminal/error and finishes the shot',
      () {
        fakeAsync((async) {
          scaleController.emitWeight(0.0);
          final sequencer = makeSequencer();
          final decisions = <ShotDecision>[];
          final states = <ShotState>[];
          sequencer.decisions.listen(decisions.add);
          sequencer.state.listen(states.add);

          async.elapse(Duration(milliseconds: 10));
          driveToPouring();
          async.elapse(Duration(milliseconds: 10));

          testDe1.emitStateAndSubstate(
            MachineState.error,
            MachineSubstate.idle,
          );
          async.elapse(Duration(milliseconds: 10));

          final terminal = decisions.singleWhere(
            (d) => d.kind == ShotDecisionKind.terminal,
          );
          expect(terminal.reason, ShotDecisionReason.error);
          expect(sequencer.finalStopReason, ShotDecisionReason.error);
          expect(states, contains(ShotState.finished));

          sequencer.dispose();
        });
      },
    );

    test('stopping backstop emits finalize/stoppingBackstop and preserves '
        'the stop trigger as final reason', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer();
        final decisions = <ShotDecision>[];
        final states = <ShotState>[];
        sequencer.decisions.listen(decisions.add);
        sequencer.state.listen(states.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(40.0);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouring,
        );
        async.elapse(Duration(milliseconds: 10));

        scaleController.emitWeight(40.0, weightFlow: 1.0);
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.pouringDone,
        );
        async.elapse(Duration(milliseconds: 10));

        async.elapse(Duration(seconds: 5));

        final finalize = decisions.singleWhere(
          (d) => d.kind == ShotDecisionKind.finalize,
        );
        expect(finalize.reason, ShotDecisionReason.stoppingBackstop);
        expect(
          sequencer.finalStopReason,
          ShotDecisionReason.targetWeight,
          reason:
              'the backstop closes the settling window; it is not why '
              'the shot stopped',
        );
        expect(states, contains(ShotState.finished));

        sequencer.dispose();
      });
    });

    test('abort during preheat (machine leaves espresso before the pour) '
        'emits an abort decision and never reaches finished', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer();
        final decisions = <ShotDecision>[];
        final states = <ShotState>[];
        sequencer.decisions.listen(decisions.add);
        sequencer.state.listen(states.add);

        async.elapse(Duration(milliseconds: 10));
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.preparingForShot,
        );
        async.elapse(Duration(milliseconds: 10));

        testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
        async.elapse(Duration(milliseconds: 10));

        final abort = decisions.singleWhere(
          (d) => d.kind == ShotDecisionKind.abort,
        );
        expect(abort.reason, ShotDecisionReason.machineEnded);
        expect(
          states,
          isNot(contains(ShotState.finished)),
          reason:
              'an aborted preheat is torn down by the manager, not '
              'persisted via the finished path',
        );

        sequencer.dispose();
      });
    });

    test('a preheat abort with a recorded app-stop intent is attributed to '
        'appStop', () {
      fakeAsync((async) {
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer();
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        testDe1.emitStateAndSubstate(
          MachineState.espresso,
          MachineSubstate.preparingForShot,
        );
        async.elapse(Duration(milliseconds: 10));

        de1Controller.recordStopIntent(ShotDecisionReason.appStop);
        testDe1.emitStateAndSubstate(MachineState.idle, MachineSubstate.idle);
        async.elapse(Duration(milliseconds: 10));

        expect(
          decisions.singleWhere((d) => d.kind == ShotDecisionKind.abort).reason,
          ShotDecisionReason.appStop,
        );

        sequencer.dispose();
      });
    });

    test('a frame regression then recovery does not double-report the '
        'advance', () {
      fakeAsync((async) {
        final profile = _profileWithSteps([
          _pressureStep(name: 'a'),
          _pressureStep(name: 'b'),
        ]);
        scaleController.emitWeight(0.0);
        final sequencer = makeSequencer(profile: profile, targetYield: 200);
        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);

        async.elapse(Duration(milliseconds: 10));
        driveToPouring();
        async.elapse(Duration(milliseconds: 10));

        for (final frame in [0, 1, 0, 1]) {
          emitPouringFrame(frame);
          async.elapse(Duration(milliseconds: 10));
        }

        expect(
          decisions.where((d) => d.reason == ShotDecisionReason.profileAdvance),
          hasLength(1),
          reason:
              'a BLE frame reorder must not re-emit an advance already '
              'reported',
        );

        sequencer.dispose();
      });
    });

    test('blockOnNoScale abort carries kind abort', () {
      fakeAsync((async) {
        scaleController.simulateDisconnect();

        final sequencer = ShotSequencer(
          scaleController: scaleController,
          de1controller: de1Controller,
          persistenceController: persistenceController,
          targetProfile: _simpleProfile(),
          targetYield: 36.0,
          bypassSAW: false,
          blockOnNoScale: true,
          weightFlowMultiplier: 0.0,
          volumeFlowMultiplier: 0.0,
          stepExitArbiterEnabled: true,
        );

        final decisions = <ShotDecision>[];
        sequencer.decisions.listen(decisions.add);
        async.elapse(Duration(milliseconds: 10));

        expect(decisions.single.kind, ShotDecisionKind.abort);
        expect(decisions.single.reason, ShotDecisionReason.noScale);

        sequencer.dispose();
      });
    });
  });
}
