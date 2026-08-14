import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/replay/shot_replayer.dart';
import 'package:clock/clock.dart';
import 'package:reaprime/src/models/device/impl/simulated_shot_weight_model.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/cup_warmer.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/simulated_shot_library.dart';
import 'package:rxdart/subjects.dart';

class MockReplayDe1 implements BengleInterface, SimulatedDevice {
  MockReplayDe1({required SimulatedShotLibrary library, Random? random})
    : _library = library,
      _random = random ?? Random();

  final SimulatedShotLibrary _library;
  final Random _random;

  final MockDe1 _synthetic = MockDe1(deviceId: "MockReplayDe1-synthetic");

  final StreamController<MachineSnapshot> _snapshots =
      StreamController.broadcast();
  final BehaviorSubject<ScaleSnapshot> _weight = BehaviorSubject();
  StreamSubscription<MachineSnapshot>? _syntheticSub;
  Timer? _timer;

  MachineState _state = MachineState.idle;
  Profile? _profile;
  String? _forcedShotId;
  ShotReplayer? _replayer;
  DateTime _replayStartedAt = clock.now();
  double _replayWeightGrams = 0.0;
  double _originalDurationSeconds = 0.0;

  final SimulatedShotWeightModel _weightModel = SimulatedShotWeightModel();

  double _sawTarget = 0.0;
  final BehaviorSubject<double> _sawTargetSubject = BehaviorSubject.seeded(0.0);

  static const double _prepSeconds = 0.3;

  @override
  String get deviceId => "MockReplayDe1";
  @override
  String get name => "Replay DE1";
  @override
  DeviceType get type => DeviceType.machine;
  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;
  @override
  TransportType get transportType => TransportType.unknown;
  @override
  MachineInfo get machineInfo => _synthetic.machineInfo;
  @override
  Stream<ConnectionState> get connectionState => _synthetic.connectionState;

  @override
  Future<void> onConnect() async {
    await _synthetic.onConnect();
    _syntheticSub = _synthetic.currentSnapshot.listen((s) {
      if (_replayer != null) return;
      _snapshots.add(s);
      _weightModel
        ..targetVolumeCountStart = _synthetic.targetVolumeCountStart
        ..ingest(s);
      final weight = _weightModel.weight;
      _emitWeight(weight);
      if (_sawTarget > 0.0 &&
          _state == MachineState.hotWater &&
          weight >= _sawTarget) {
        unawaited(requestState(MachineState.idle));
      }
    });
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _tick(),
    );
    _emitWeight(0);
  }

  @override
  disconnect() async {
    _timer?.cancel();
    _timer = null;
    await _syntheticSub?.cancel();
    _syntheticSub = null;
    _replayer = null;
    await _synthetic.disconnect();
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _syntheticSub?.cancel();
    await _snapshots.close();
    await _weight.close();
    await _sawTargetSubject.close();
    await _led.close();
    await _stopAtTempSubject.close();
    await _synthetic.dispose();
  }

  @override
  Stream<MachineSnapshot> get currentSnapshot => _snapshots.stream;

  @override
  Future<void> requestState(MachineState newState) async {
    if (newState == MachineState.skipStep && _replayer != null) {
      _seekToNextFrame();
      return;
    }
    _state = newState;
    if (newState == MachineState.espresso) {
      _startReplay();
    } else {
      _replayer = null;
      await _synthetic.requestState(newState);
    }
  }

  void _seekToNextFrame() {
    final replayer = _replayer!;
    final now = clock.now();
    final replayElapsed =
        now.difference(_replayStartedAt).inMilliseconds / 1000.0 - _prepSeconds;
    final boundary = replayer.nextFrameBoundaryAfter(replayElapsed);
    if (boundary == null) return;
    _replayStartedAt = now.subtract(
      Duration(microseconds: ((boundary + _prepSeconds) * 1e6).round()),
    );
  }

  @override
  Future<void> setProfile(Profile profile) async {
    _profile = profile;
    await _synthetic.setProfile(profile);
  }

  void _startReplay() {
    _replayWeightGrams = 0.0;
    final shot =
        (_forcedShotId != null ? _library.byId(_forcedShotId!) : null) ??
        _library.pickForProfile(_profile?.title, _random);
    if (shot == null || shot.measurements.isEmpty) {
      _replayer = null;
      return;
    }
    _replayer = ShotReplayer(shot.measurements);
    _originalDurationSeconds =
        _library.originalDurationOf(shot.id) ?? _replayer!.durationSeconds;
    _replayStartedAt = clock.now();
  }

  List<SimulatedShot> get availableShots => _library.catalog;

  String? get selectedShotId => _forcedShotId;

  /// Session-only override; false if [id] is not a bundled recording.
  bool selectShot(String id) {
    if (_library.byId(id) == null) return false;
    _forcedShotId = id;
    return true;
  }

  void clearSelectedShot() => _forcedShotId = null;

  void _tick() {
    final replayer = _replayer;
    if (replayer == null || _state != MachineState.espresso) return;
    final now = clock.now();
    final elapsed = now.difference(_replayStartedAt).inMilliseconds / 1000.0;

    // A synthetic pre-shot phase runs first with the scale held at 0; the
    // recording then plays from its own t=0, so the replay clock is offset by
    // the prep duration.
    if (elapsed < _prepSeconds) {
      _replayWeightGrams = 0.0;
      _snapshots.add(
        replayer
            .frameAt(0, timestamp: now)
            .copyWith(
              state: const MachineStateSnapshot(
                state: MachineState.espresso,
                substate: MachineSubstate.preparingForShot,
              ),
            ),
      );
      _emitWeight(0);
      return;
    }

    final replayElapsed = elapsed - _prepSeconds;
    _replayWeightGrams =
        replayer.scaleAt(replayElapsed)?.weight ?? _replayWeightGrams;
    _snapshots.add(replayer.frameAt(replayElapsed, timestamp: now));
    _emitWeight(_replayWeightGrams);

    if (_sawTarget > 0.0 && _replayWeightGrams >= _sawTarget) {
      _replayer = null;
      unawaited(requestState(MachineState.idle));
      return;
    }
    // Without a positive target, end at the recording's real endpoint; only a
    // target beyond the recorded final weight plays into the extrapolated tail.
    final endTime = _sawTarget > 0.0
        ? replayer.durationSeconds
        : _originalDurationSeconds;
    if (replayElapsed >= endTime) {
      _replayer = null;
      unawaited(requestState(MachineState.idle));
    }
  }

  void _emitWeight(double grams) {
    if (_weight.isClosed) return;
    _weight.add(
      ScaleSnapshot(timestamp: clock.now(), weight: grams, batteryLevel: 100),
    );
  }

  @override
  Stream<ScaleSnapshot> get weightSnapshot => _weight.stream;

  @override
  Future<void> tareIntegratedScale() async {
    // While replaying espresso the recording is immutable and already starts
    // from zero, so a tare is swallowed; otherwise reset the synthetic model.
    if (_replayer != null) return;
    _weightModel.tare();
    _emitWeight(0);
  }

  @override
  Future<void> setStopAtWeightTarget(double grams) async {
    _sawTarget = grams.clamp(0.0, 10000.0);
    _sawTargetSubject.add(_sawTarget);
  }

  @override
  Future<double> getStopAtWeightTarget() async => _sawTarget;

  @override
  Stream<double> get stopAtWeightTarget => _sawTargetSubject.stream;

  double _cupWarmer = 0.0;
  @override
  Future<void> setCupWarmerTemperature(double celsius) async =>
      _cupWarmer = celsius.clamp(0.0, 80.0);
  @override
  Future<double> getCupWarmerTemperature() async => _cupWarmer;
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

  final BehaviorSubject<LedStripState> _led = BehaviorSubject.seeded(
    const LedStripState(),
  );
  @override
  Stream<LedStripState> get ledStripState => _led.stream;
  @override
  Future<LedStripState> getLedStripState() async => _led.value;
  @override
  Future<void> setLedStrip(LedStripState state) async => _led.add(state);
  @override
  Future<void> commitLedStrip() async {}
  @override
  Future<LedStripState?> resetLedStrip() async => _led.value;

  @override
  bool get supportsCurrentBengleFirmwareSurface => true;

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

  double _stopAtTemp = 0.0;
  final BehaviorSubject<double> _stopAtTempSubject = BehaviorSubject.seeded(
    0.0,
  );
  @override
  Future<void> setStopAtTemperatureTarget(double celsius) async {
    _stopAtTemp = celsius.clamp(0.0, 85.0);
    _stopAtTempSubject.add(_stopAtTemp);
  }

  @override
  Future<double> getStopAtTemperatureTarget() async => _stopAtTemp;
  @override
  Stream<double> get stopAtTemperatureTarget => _stopAtTempSubject.stream;
  @override
  Stream<bool> get probeAttached => Stream<bool>.value(false);
  @override
  Stream<double> get probeTemperature => const Stream<double>.empty();

  @override
  Stream<bool> get ready => _synthetic.ready;
  @override
  Stream<De1RawMessage> get rawOutStream => _synthetic.rawOutStream;
  @override
  void sendRawMessage(De1RawMessage message) =>
      _synthetic.sendRawMessage(message);
  @override
  Stream<De1ShotSettings> get shotSettings => _synthetic.shotSettings;
  @override
  Future<void> updateShotSettings(De1ShotSettings s) =>
      _synthetic.updateShotSettings(s);
  @override
  Stream<De1WaterLevels> get waterLevels => _synthetic.waterLevels;
  @override
  Future<void> setRefillLevel(int level) => _synthetic.setRefillLevel(level);
  @override
  Future<De1RefillKitSettings> getRefillKitSettings() =>
      _synthetic.getRefillKitSettings();
  @override
  Future<void> setRefillKitSettings(De1RefillKitSettings s) =>
      _synthetic.setRefillKitSettings(s);
  @override
  Future<void> setFanThreshhold(int temp) => _synthetic.setFanThreshhold(temp);
  @override
  Future<int> getFanThreshhold() => _synthetic.getFanThreshhold();
  @override
  Future<int> getTankTempThreshold() => _synthetic.getTankTempThreshold();
  @override
  Future<void> setTankTempThreshold(int temp) =>
      _synthetic.setTankTempThreshold(temp);
  @override
  Future<void> setSteamFlow(double f) => _synthetic.setSteamFlow(f);
  @override
  Future<double> getSteamFlow() => _synthetic.getSteamFlow();
  @override
  Future<void> setHotWaterFlow(double f) => _synthetic.setHotWaterFlow(f);
  @override
  Future<double> getHotWaterFlow() => _synthetic.getHotWaterFlow();
  @override
  Future<void> setFlushFlow(double f) => _synthetic.setFlushFlow(f);
  @override
  Future<double> getFlushFlow() => _synthetic.getFlushFlow();
  @override
  Future<void> setFlushTimeout(double t) => _synthetic.setFlushTimeout(t);
  @override
  Future<double> getFlushTimeout() => _synthetic.getFlushTimeout();
  @override
  Future<double> getFlushTemperature() => _synthetic.getFlushTemperature();
  @override
  Future<void> setFlushTemperature(double t) =>
      _synthetic.setFlushTemperature(t);
  @override
  Future<double> getFlowEstimation() => _synthetic.getFlowEstimation();
  @override
  Future<void> setFlowEstimation(double m) => _synthetic.setFlowEstimation(m);
  @override
  double? get cachedFlowEstimation => _synthetic.cachedFlowEstimation;
  @override
  Future<De1HeaterVoltage> getHeaterVoltage() => _synthetic.getHeaterVoltage();
  @override
  Future<void> setHeaterVoltage(De1HeaterVoltage v) =>
      _synthetic.setHeaterVoltage(v);
  @override
  Future<bool> getUsbChargerMode() => _synthetic.getUsbChargerMode();
  @override
  Future<void> setUsbChargerMode(bool t) => _synthetic.setUsbChargerMode(t);
  @override
  Future<void> setSteamPurgeMode(int mode) =>
      _synthetic.setSteamPurgeMode(mode);
  @override
  Future<int> getSteamPurgeMode() => _synthetic.getSteamPurgeMode();
  @override
  Future<void> enableUserPresenceFeature() =>
      _synthetic.enableUserPresenceFeature();
  @override
  Future<void> sendUserPresent() => _synthetic.sendUserPresent();
  @override
  Future<double> getHeaterPhase1Flow() => _synthetic.getHeaterPhase1Flow();
  @override
  Future<void> setHeaterPhase1Flow(double v) =>
      _synthetic.setHeaterPhase1Flow(v);
  @override
  Future<double> getHeaterPhase2Flow() => _synthetic.getHeaterPhase2Flow();
  @override
  Future<void> setHeaterPhase2Flow(double v) =>
      _synthetic.setHeaterPhase2Flow(v);
  @override
  Future<double> getHeaterPhase2Timeout() =>
      _synthetic.getHeaterPhase2Timeout();
  @override
  Future<void> setHeaterPhase2Timeout(double v) =>
      _synthetic.setHeaterPhase2Timeout(v);
  @override
  Future<double> getHeaterIdleTemp() => _synthetic.getHeaterIdleTemp();
  @override
  Future<void> setHeaterIdleTemp(double v) => _synthetic.setHeaterIdleTemp(v);
  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  }) => _synthetic.updateFirmware(fwImage, onProgress: onProgress);
  @override
  FirmwareUpdateState get firmwareUpdateState => _synthetic.firmwareUpdateState;
  @override
  Future<void> cancelFirmwareUpload() => _synthetic.cancelFirmwareUpload();
}
