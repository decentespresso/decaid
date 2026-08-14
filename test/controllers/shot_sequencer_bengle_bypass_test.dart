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
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/cup_warmer.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/test_de1.dart';
import '../helpers/test_scale.dart';

class _TestBengle extends TestDe1 implements BengleInterface {
  final List<double> sawWrites = [];

  @override
  Future<void> setStopAtWeightTarget(double grams) async {
    sawWrites.add(grams);
  }

  @override
  Future<double> getStopAtWeightTarget() async => 0.0;

  @override
  Stream<double> get stopAtWeightTarget => const Stream.empty();

  @override
  Future<void> setCupWarmerTemperature(double celsius) async {}
  @override
  Future<double> getCupWarmerTemperature() async => 0.0;
  @override
  Future<void> setCupWarmerEnabled(bool enabled) async {}
  @override
  Future<bool> getCupWarmerEnabled() async => false;
  @override
  Future<double?> getCupWarmerCurrentTemperature() async => null;
  @override
  Future<void> setCupWarmerPreheat({
    required bool enabled,
    required int leadMinutes,
  }) async {}
  @override
  Future<CupWarmerPreheatState> getCupWarmerPreheatState() async =>
      const CupWarmerPreheatState(
        enabled: false,
        leadMinutes: 0,
        active: false,
      );
  @override
  Future<void> setInactivitySleepTimeout(int minutes) async {}
  @override
  Future<void> pushFirmwareWakeSchedule({
    required int secondsSinceSundayLocal,
    required List<FirmwareWakeWindow> windows,
  }) async {}
  @override
  Stream<ScaleSnapshot> get weightSnapshot => const Stream.empty();
  @override
  Future<void> tareIntegratedScale() async {}
  @override
  Stream<LedStripState> get ledStripState => const Stream.empty();
  @override
  Future<LedStripState> getLedStripState() async => const LedStripState();
  @override
  Future<void> setLedStrip(LedStripState state) async {}
  @override
  Future<void> commitLedStrip() async {}
  @override
  Future<LedStripState?> resetLedStrip() async => const LedStripState();

  @override
  Future<void> setStopAtTemperatureTarget(double celsius) async {}
  @override
  Future<double> getStopAtTemperatureTarget() async => 0.0;
  @override
  Stream<double> get stopAtTemperatureTarget => const Stream.empty();
  @override
  Stream<bool> get probeAttached => const Stream.empty();
  @override
  Stream<double> get probeTemperature => const Stream.empty();

  @override
  Future<ScaleCalibrationState> getScaleCalibrationState() async =>
      const ScaleCalibrationState(
        step: ScaleCalibrationStep.idle,
        detectedCell: ScaleCalibrationCell.none,
        subState: ScaleCalibrationSubState.settling,
        secondsRemaining: 0,
        status: ScaleCalibrationStatus.none,
      );

  @override
  Future<bool> startScaleCalibration(
    ScaleCalibrationCommand command, {
    double? weightGrams,
  }) async => true;
}

class _FakeDiscoveryService extends DeviceDiscoveryService {
  @override
  Stream<List<Device>> get devices => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
}

class _BengleDe1Controller extends De1Controller {
  final _TestBengle bengle;

  _BengleDe1Controller(this.bengle)
    : super(controller: DeviceController([_FakeDiscoveryService()]));

  @override
  De1Interface connectedDe1() => bengle;

  @override
  Stream<De1Interface?> get de1 => BehaviorSubject.seeded(bengle).stream;
}

class _TestScaleController extends ScaleController {
  final TestScale testScale;
  final BehaviorSubject<ConnectionState> _connectionState;
  final BehaviorSubject<WeightSnapshot> _weight = BehaviorSubject();

  _TestScaleController(this.testScale)
    : _connectionState = BehaviorSubject.seeded(ConnectionState.connected);

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;
  @override
  ConnectionState get currentConnectionState => _connectionState.value;
  @override
  Stream<WeightSnapshot> get weightSnapshot => _weight.stream;

  @override
  Scale connectedScale() {
    if (_connectionState.value != ConnectionState.connected) {
      throw 'No scale connected';
    }
    return testScale;
  }

  void emitWeight(double weight, {double weightFlow = 0.0}) {
    _weight.add(
      WeightSnapshot(
        timestamp: DateTime(2026, 1, 15, 8, 0),
        weight: weight,
        weightFlow: weightFlow,
      ),
    );
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

Profile _simpleProfile() => Profile(
  version: '2',
  title: 'T',
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
  group(
    'ShotSequencer bypasses app-side SAW when machine is BengleInterface',
    () {
      late _TestBengle bengle;
      late _BengleDe1Controller de1Controller;
      late TestScale testScale;
      late _TestScaleController scaleController;
      late PersistenceController persistence;
      late Profile profile;

      setUp(() {
        bengle = _TestBengle();
        de1Controller = _BengleDe1Controller(bengle);
        testScale = TestScale();
        scaleController = _TestScaleController(testScale);
        persistence = PersistenceController(
          storageService: _NullStorageService(),
        );
        profile = _simpleProfile();
      });

      tearDown(() {
        bengle.dispose();
        testScale.dispose();
        scaleController.dispose();
        persistence.dispose();
      });

      test(
        'does not request idle even when projected weight exceeds target',
        () {
          fakeAsync((async) {
            scaleController.emitWeight(0.0);

            final shot = ShotSequencer(
              scaleController: scaleController,
              de1controller: de1Controller,
              persistenceController: persistence,
              targetProfile: profile,
              targetYield: 30.0,
              bypassSAW: false,
              blockOnNoScale: false,
              weightFlowMultiplier: 0.0,
              volumeFlowMultiplier: 0.0,
              stepExitArbiterEnabled: true,
            );

            async.elapse(const Duration(milliseconds: 10));

            bengle.emitStateAndSubstate(
              MachineState.espresso,
              MachineSubstate.preparingForShot,
            );
            bengle.emitStateAndSubstate(
              MachineState.espresso,
              MachineSubstate.pouring,
            );
            async.elapse(const Duration(milliseconds: 10));

            scaleController.emitWeight(40.0);
            bengle.emitStateAndSubstate(
              MachineState.espresso,
              MachineSubstate.pouring,
            );
            async.elapse(const Duration(milliseconds: 10));

            expect(
              bengle.requestedStates,
              isEmpty,
              reason:
                  'BengleInterface machine runs autonomous SAW; ShotSequencer '
                  'must not double-stop the shot',
            );

            shot.dispose();
          });
        },
      );
    },
  );
}
