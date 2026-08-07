import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

// ignore: unused_field
enum _SimulationType { espresso, steam, hotWater, idle }

class MockDe1 implements De1Interface, SimulatedDevice {
  MockDe1({String deviceId = "MockDe1"}) : _deviceId = deviceId;

  static double _applyLimiter(double measurement, StepLimiter? limiter) {
    if (limiter == null || limiter.value <= 0 || measurement <= limiter.value) {
      return measurement;
    }
    if (limiter.range <= 0) {
      return limiter.value;
    }
    final excess = measurement - limiter.value;
    return limiter.value + limiter.range * excess / (limiter.range + excess);
  }

  final Random _puckRandom = Random(0);
  double _puckResistanceMultiplier = 1.0;

  final StreamController<MachineSnapshot> _snapshotStream =
      StreamController.broadcast();

  final _log = Logger("MockDe1");

  Timer? _stateTimer;

  MachineSnapshot _lastSnapshot = MachineSnapshot(
    flow: 0,
    state: MachineStateSnapshot(
      state: MachineState.idle,
      substate: MachineSubstate.pouring,
    ),
    steamTemperature: 0,
    profileFrame: 0,
    targetFlow: 0,
    targetPressure: 0,
    targetMixTemperature: 0,
    targetGroupTemperature: 0,
    timestamp: DateTime.now(),
    groupTemperature: 0,
    mixTemperature: 0,
    pressure: 0,
  );

  MachineState _currentState = MachineState.booting;
  _SimulationType _simulationType = _SimulationType.idle;

  Profile? _currentProfile;
  int _currentProfileStepIndex = 0;
  double _profileStepElapsedTime = 0.0;
  double _profileTargetTemperature = 94.0;
  int _targetVolumeCountStart = 0;

  int get targetVolumeCountStart => _targetVolumeCountStart;
  double _fromFlowTarget = 0;
  double _fromPressureTarget = 0;

  @override
  Stream<MachineSnapshot> get currentSnapshot => _snapshotStream.stream;

  final String _deviceId;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;

  @override
  String get name => "MockDe1";

  @override
  MachineInfo get machineInfo => MachineInfo(
    version: "1337",
    model: "DE1Pro",
    serialNumber: const String.fromEnvironment(
      'MOCK_DE1_SERIAL',
      defaultValue: 'mock-de1',
    ),
    groupHeadControllerPresent: false,
    extra: {},
  );

  @override
  Future<void> requestState(MachineState newState) async {
    _currentState = newState;
    if (_currentState == MachineState.espresso) {
      shotTime = 0.0;
      _simulationType = _SimulationType.espresso;
      _currentProfileStepIndex = 0;
      _profileStepElapsedTime = 0.0;
      _espressoTickCount = 0;
      _pouringDoneTicks = 0;
      _shotElapsedMs = 0.0;
      _fromFlowTarget = 0;
      _fromPressureTarget = 0;
      _puckResistanceMultiplier = 0.85 + _puckRandom.nextDouble() * 0.3;
    } else if (_currentState == MachineState.hotWater) {
      _simulationType = _SimulationType.hotWater;
      _hotWaterElapsedMs = 0.0;
    } else if (_currentState == MachineState.skipStep &&
        _simulationType == _SimulationType.espresso &&
        _currentProfile != null) {
      if (_currentProfileStepIndex < _currentProfile!.steps.length - 1) {
        _captureFromTargets(_currentProfile!.steps[_currentProfileStepIndex]);
        _currentProfileStepIndex++;
        _profileStepElapsedTime = 0.0;
        _espressoTickCount = 0;
        _log.fine("skipStep: advanced to step $_currentProfileStepIndex");
      }
      _currentState = MachineState.espresso;
    } else {
      _simulationType = _SimulationType.idle;
    }
  }

  @override
  Future<void> onConnect() async {
    _connectionState.add(ConnectionState.connected);
    _currentState = MachineState.idle;
    _simulateState();
  }

  @override
  disconnect() async {
    await cancelFirmwareUpload();
    await onDisconnect();
  }

  @override
  Future<void> dispose() async {}

  @override
  DeviceType get type => DeviceType.machine;

  DateTime lastIdleSnapshot = DateTime.now();
  void _simulateState() {
    _snapshotStream.add(_lastSnapshot);

    _stateTimer = Timer.periodic(Duration(milliseconds: 100), (t) {
      MachineSnapshot newSnapshot;
      switch (_simulationType) {
        case _SimulationType.espresso:
          newSnapshot = _simulateEspresso();
          break;
        case _SimulationType.hotWater:
          newSnapshot = _simulateHotWater();
          break;
        case _SimulationType.idle:
          if (DateTime.now().difference(lastIdleSnapshot).inMilliseconds <
              500) {
            return;
          }
          lastIdleSnapshot = DateTime.now();
          newSnapshot = _simulateIdle();
        default:
          newSnapshot = _simulateIdle();
      }
      _snapshotStream.add(newSnapshot);
      _lastSnapshot = newSnapshot;
    });
  }

  MachineSnapshot _simulateIdle() {
    final targetTemp = _profileTargetTemperature;

    double tempChangeRate = 0.5;
    if ((_lastSnapshot.mixTemperature - targetTemp).abs() < 5) {
      tempChangeRate = 0.2;
    }

    final newMixTemp = _calculateTemperature(
      current: _lastSnapshot.mixTemperature,
      target: targetTemp,
      rate: tempChangeRate,
    );

    final newGroupTemp = _calculateTemperature(
      current: _lastSnapshot.groupTemperature,
      target: targetTemp,
      rate: tempChangeRate,
    );

    return MachineSnapshot(
      timestamp: lastIdleSnapshot,
      state: MachineStateSnapshot(
        state: _currentState,
        substate: MachineSubstate.idle,
      ),
      flow: 0,
      pressure: 0,
      targetFlow: 0,
      targetPressure: 0,
      mixTemperature: newMixTemp,
      groupTemperature: newGroupTemp,
      targetMixTemperature: targetTemp,
      targetGroupTemperature: targetTemp,
      profileFrame: 0,
      steamTemperature: min(_lastSnapshot.steamTemperature + 1, 150),
    );
  }

  double shotTime = 0.0;
  int _espressoTickCount = 0;
  int _pouringDoneTicks = 0;
  double _shotElapsedMs = 0.0;

  MachineSnapshot _simulateEspresso() {
    MachineSubstate substate = _lastSnapshot.state.substate;

    switch (_lastSnapshot.pressure) {
      case < 0.5:
        substate = MachineSubstate.preparingForShot;
        break;
      case > 1.0:
        substate = MachineSubstate.pouring;
      default:
        break;
    }

    shotTime +=
        DateTime.now().millisecondsSinceEpoch -
        _lastSnapshot.timestamp.millisecondsSinceEpoch;

    if (_currentProfile != null && _currentProfile!.steps.isNotEmpty) {
      return _simulateWithProfile();
    }

    if (shotTime > 30000) {
      _simulationType = _SimulationType.idle;
      _currentState = MachineState.idle;
    }
    return _fallbackEspressoSimulation(substate);
  }

  MachineSnapshot _simulateWithProfile() {
    if (_currentProfile == null) {
      return _fallbackEspressoSimulation(_lastSnapshot.state.substate);
    }

    _profileStepElapsedTime += 100;

    final currentStep = _currentProfile!.steps[_currentProfileStepIndex];

    final stepDurationMs = currentStep.seconds * 1000;
    final exitMet = _stepExitConditionMet(currentStep);
    if ((_profileStepElapsedTime >= stepDurationMs || exitMet) &&
        _pouringDoneTicks == 0) {
      if (_currentProfileStepIndex < _currentProfile!.steps.length - 1) {
        _captureFromTargets(currentStep);
        _currentProfileStepIndex++;
        _profileStepElapsedTime = 0.0;
        _log.fine("Moving to profile step: $_currentProfileStepIndex");
      } else {
        _pouringDoneTicks = 3;
        _log.fine("Profile completed, pouringDone transition");
      }
    }

    final stepProgress = stepDurationMs > 0
        ? min(_profileStepElapsedTime / stepDurationMs, 1.0)
        : 0.0;

    _shotElapsedMs += 100;
    final shotSecs = _shotElapsedMs / 1000.0;

    const rDry = 0.10;
    const rPeak = 4.2;
    const rErode = 2.5;
    const peakSecs = 12.0;
    const erodeSecs = 16.0;
    double resistance;
    if (shotSecs <= peakSecs) {
      final s = shotSecs / peakSecs;
      resistance = rDry + (rPeak - rDry) * s * s * s;
    } else {
      final e = min((shotSecs - peakSecs) / erodeSecs, 1.0);
      resistance = rPeak - (rPeak - rErode) * e;
    }
    resistance *= _puckResistanceMultiplier;

    final targetTemp = currentStep.temperature;
    const dipMax = 16.0;
    const dipTauSecs = 3.0;
    final inPrep = _espressoTickCount < 5;
    final contactSecs = max(0.0, shotSecs - 0.5);
    final dip = inPrep ? 0.0 : dipMax * exp(-contactSecs / dipTauSecs);
    final newGroupTemp = targetTemp - dip;
    final newMixTemp = newGroupTemp - 1.0;

    const flowResponseRate = 0.35;
    const pressureDamping = 0.35;

    double targetFlow;
    double targetPressure;
    double stepTargetFlow;
    double stepTargetPressure;
    if (currentStep is ProfileStepPressure) {
      stepTargetPressure = currentStep.pressure;
      stepTargetFlow = 0;
      targetPressure = currentStep.pressure;
      targetFlow = 8.0;
    } else if (currentStep is ProfileStepFlow) {
      stepTargetFlow = currentStep.flow;
      stepTargetPressure = 0;
      targetFlow = currentStep.flow;
      targetPressure = 0;
    } else {
      stepTargetFlow = 4.0;
      stepTargetPressure = 0.0;
      targetFlow = 4.0;
      targetPressure = 0.0;
    }

    if (currentStep.transition == TransitionType.smooth) {
      if (currentStep is ProfileStepPressure) {
        targetPressure =
            _fromPressureTarget +
            (targetPressure - _fromPressureTarget) * stepProgress;
        stepTargetPressure = targetPressure;
      } else if (currentStep is ProfileStepFlow) {
        targetFlow =
            _fromFlowTarget + (targetFlow - _fromFlowTarget) * stepProgress;
        stepTargetFlow = targetFlow;
      }
    }

    double newFlow =
        _lastSnapshot.flow +
        (targetFlow - _lastSnapshot.flow) * flowResponseRate;

    if (currentStep is ProfileStepPressure) {
      newFlow = _applyLimiter(newFlow, currentStep.limiter);
    }

    final unboundedPressure = newFlow * resistance;
    double newPressure =
        _lastSnapshot.pressure +
        (unboundedPressure - _lastSnapshot.pressure) * pressureDamping;

    const pumpMaxFlow = 8.0;

    if (currentStep is ProfileStepPressure) {
      if (newPressure >= targetPressure) {
        newPressure = targetPressure;
        newFlow = min(targetPressure / resistance, pumpMaxFlow);
        newFlow = _applyLimiter(newFlow, currentStep.limiter);
      }
    }

    if (currentStep is ProfileStepFlow && newFlow > targetFlow) {
      newFlow = targetFlow;
    }
    if (currentStep is ProfileStepFlow) {
      final limitedPressure = _applyLimiter(newPressure, currentStep.limiter);
      if (limitedPressure < newPressure) {
        newPressure = limitedPressure;
        newFlow = min(newFlow, limitedPressure / resistance);
      }
    }

    const physicalMaxPressure = 11.0;
    if (newPressure > physicalMaxPressure) {
      newPressure = physicalMaxPressure;
      newFlow = min(physicalMaxPressure / resistance, pumpMaxFlow);
    }

    _espressoTickCount++;

    MachineSubstate substate;
    if (_pouringDoneTicks > 0) {
      substate = MachineSubstate.pouringDone;
      _pouringDoneTicks--;
      if (_pouringDoneTicks == 0) {
        _simulationType = _SimulationType.idle;
        _currentState = MachineState.idle;
      }
    } else if (_espressoTickCount <= 5) {
      substate = MachineSubstate.preparingForShot;
    } else if (_currentProfileStepIndex < _targetVolumeCountStart) {
      substate = MachineSubstate.preinfusion;
    } else {
      substate = MachineSubstate.pouring;
    }

    return MachineSnapshot(
      timestamp: DateTime.now(),
      state: MachineStateSnapshot(state: _currentState, substate: substate),
      flow: newFlow,
      pressure: newPressure,
      targetFlow: stepTargetFlow,
      targetPressure: stepTargetPressure,
      mixTemperature: newMixTemp,
      groupTemperature: newGroupTemp,
      targetMixTemperature: targetTemp,
      targetGroupTemperature: targetTemp,
      profileFrame: _currentProfileStepIndex,
      steamTemperature: _calculateTemperature(
        current: _lastSnapshot.steamTemperature.toDouble(),
        target: 150.0,
        rate: 0.2,
      ).toInt(),
    );
  }

  double _hotWaterElapsedMs = 0.0;

  MachineSnapshot _simulateHotWater() {
    _hotWaterElapsedMs += 100;
    final settings = _shotSettingsController.value;
    if (_hotWaterElapsedMs >= settings.targetHotWaterDuration * 1000) {
      _simulationType = _SimulationType.idle;
      _currentState = MachineState.idle;
    }
    final done = _currentState != MachineState.hotWater;
    final targetTemp = settings.targetHotWaterTemp.toDouble();
    final targetFlow = done ? 0.0 : _hotWaterFlow;
    final newFlow =
        _lastSnapshot.flow + (targetFlow - _lastSnapshot.flow) * 0.35;
    return MachineSnapshot(
      timestamp: DateTime.now(),
      state: MachineStateSnapshot(
        state: _currentState,
        substate: done ? MachineSubstate.idle : MachineSubstate.pouring,
      ),
      flow: newFlow,
      pressure: newFlow * 0.25,
      targetFlow: targetFlow,
      targetPressure: 0,
      mixTemperature: _calculateTemperature(
        current: _lastSnapshot.mixTemperature,
        target: targetTemp,
        rate: 2.0,
      ),
      groupTemperature: _calculateTemperature(
        current: _lastSnapshot.groupTemperature,
        target: targetTemp,
        rate: 2.0,
      ),
      targetMixTemperature: targetTemp,
      targetGroupTemperature: targetTemp,
      profileFrame: 0,
      steamTemperature: _lastSnapshot.steamTemperature,
    );
  }

  MachineSnapshot _fallbackEspressoSimulation(MachineSubstate substate) {
    return MachineSnapshot(
      timestamp: DateTime.now(),
      state: MachineStateSnapshot(state: _currentState, substate: substate),
      flow: min(_lastSnapshot.flow + 0.05, 4.0),
      pressure: min(_lastSnapshot.pressure + 0.04, 9.0),
      targetFlow: 4.5,
      targetPressure: 9.0,
      mixTemperature: _calculateTemperature(
        current: _lastSnapshot.mixTemperature,
        target: _profileTargetTemperature,
        rate: 0.1,
      ),
      groupTemperature: _calculateTemperature(
        current: _lastSnapshot.groupTemperature,
        target: _profileTargetTemperature,
        rate: 0.1,
      ),
      targetMixTemperature: _profileTargetTemperature,
      targetGroupTemperature: _profileTargetTemperature,
      profileFrame: 0,
      steamTemperature: min(_lastSnapshot.steamTemperature + 1, 150),
    );
  }

  bool _stepExitConditionMet(ProfileStep step) {
    final exit = step.exit;
    if (exit == null || exit.value <= 0) return false;
    final reading = exit.type == ExitType.flow
        ? _lastSnapshot.flow
        : _lastSnapshot.pressure;
    return exit.condition == ExitCondition.over
        ? reading >= exit.value
        : reading <= exit.value;
  }

  void _captureFromTargets(ProfileStep step) {
    if (step is ProfileStepPressure) {
      _fromPressureTarget = step.pressure;
      _fromFlowTarget = 0;
    } else if (step is ProfileStepFlow) {
      _fromFlowTarget = step.flow;
      _fromPressureTarget = 0;
    }
  }

  double _calculateTemperature({
    required double current,
    required double target,
    required double rate,
  }) {
    if ((current - target).abs() < rate) {
      return target;
    }
    if (current < target) {
      return min(current + rate, target);
    } else {
      return max(current - rate, target);
    }
  }

  Future<void> onDisconnect() async {
    _stateTimer?.cancel();
    _connectionState.add(ConnectionState.disconnected);
  }

  void simulateDisconnect() {
    _stateTimer?.cancel();
    _connectionState.add(ConnectionState.disconnected);
  }

  bool _chargerOn = false;
  int _steamPurgeMode = 0;
  double _flowEstimation = 1.0;

  @override
  Future<bool> getUsbChargerMode() async {
    return _chargerOn;
  }

  @override
  Future<void> setUsbChargerMode(bool t) async {
    _chargerOn = t;
  }

  @override
  Future<double> getFlowEstimation() async {
    return _flowEstimation;
  }

  @override
  double? get cachedFlowEstimation => _flowEstimation;

  @override
  Future<void> setFlowEstimation(double multiplier) async {
    _flowEstimation = multiplier;
  }

  @override
  Future<int> getSteamPurgeMode() async {
    return _steamPurgeMode;
  }

  @override
  Future<void> setSteamPurgeMode(int mode) async {
    _steamPurgeMode = mode;
  }

  @override
  Future<void> setProfile(Profile profile) async {
    _log.info("set profile: ${profile.title}");

    _currentProfile = profile;
    _targetVolumeCountStart = profile.targetVolumeCountStart;

    if (profile.steps.isNotEmpty) {
      _profileTargetTemperature = profile.steps.first.temperature;
      _log.fine("Target temperature set to: $_profileTargetTemperature");

      for (var i = 0; i < profile.steps.length; i++) {
        final step = profile.steps[i];
        _log.fine(
          "Step $i: ${step.name} - ${step.seconds}s, Temp: ${step.temperature}°C",
        );
        if (step is ProfileStepPressure) {
          _log.fine("  Pressure: ${step.pressure} bar");
        } else if (step is ProfileStepFlow) {
          _log.fine("  Flow: ${step.flow} ml/s");
        }
      }
    }

    _currentProfileStepIndex = 0;
    _profileStepElapsedTime = 0.0;
  }

  @override
  Future<void> setRefillLevel(int newRefillLevel) async {}

  final BehaviorSubject<De1ShotSettings> _shotSettingsController =
      BehaviorSubject.seeded(
        De1ShotSettings(
          steamSetting: 0,
          targetSteamTemp: 150,
          targetSteamDuration: 60,
          targetHotWaterTemp: 85,
          targetHotWaterVolume: 100,
          targetHotWaterDuration: 35,
          targetShotVolume: 36,
          groupTemp: 94,
        ),
      );

  @override
  Stream<De1ShotSettings> get shotSettings =>
      _shotSettingsController.stream.distinct();

  @override
  Future<void> updateShotSettings(De1ShotSettings newSettings) async {
    _shotSettingsController.add(newSettings);
  }

  @override
  Stream<De1WaterLevels> get waterLevels =>
      Stream.periodic(Duration(seconds: 1), (_) {
        return De1WaterLevels(currentLevel: 50.0, refillLevel: 5.0);
      });

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.discovered);

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Future<int> getFanThreshhold() async {
    return _fanThreshhold;
  }

  @override
  Future<void> setFanThreshhold(int temp) async {
    _fanThreshhold = temp;
  }

  int _fanThreshhold = 50;

  double _steamFlow = 1.0;
  @override
  Future<double> getSteamFlow() {
    return Future(() {
      return _steamFlow;
    });
  }

  @override
  Future<void> setSteamFlow(double newFlow) async {
    _steamFlow = newFlow;
  }

  double _hotWaterFlow = 1.0;
  @override
  Future<double> getHotWaterFlow() async {
    return _hotWaterFlow;
  }

  @override
  Future<void> setHotWaterFlow(double newFlow) async {
    _hotWaterFlow = newFlow;
  }

  double _flushFlow = 1.0;
  @override
  Future<double> getFlushFlow() async {
    return _flushFlow;
  }

  @override
  Future<void> setFlushFlow(double newFlow) async {
    _flushFlow = newFlow;
  }

  @override
  Future<void> setFlushTimeout(double newTimeout) async {}

  @override
  Future<double> getFlushTimeout() async {
    return 10.0;
  }

  @override
  Future<double> getFlushTemperature() async {
    return 25.0;
  }

  @override
  Future<void> setFlushTemperature(double newTemp) async {}

  @override
  Future<int> getTankTempThreshold() async {
    return 20;
  }

  @override
  Future<void> setTankTempThreshold(int temp) async {}

  @override
  Stream<bool> get ready => Stream.value(true);

  @override
  Future<double> getHeaterIdleTemp() async {
    return _heaterIdleTemp;
  }

  @override
  Future<double> getHeaterPhase1Flow() async {
    return _heaterPhase1Flow;
  }

  @override
  Future<double> getHeaterPhase2Flow() async {
    return _heaterPhase2Flow;
  }

  @override
  Future<double> getHeaterPhase2Timeout() async {
    return _heaterPhase2Timeout;
  }

  double _heaterIdleTemp = 98.0;
  double _heaterPhase1Flow = 2.5;
  double _heaterPhase2Flow = 5.0;
  double _heaterPhase2Timeout = 5.0;

  @override
  Future<void> setHeaterIdleTemp(double val) async {
    _heaterIdleTemp = val;
  }

  @override
  Future<void> setHeaterPhase1Flow(double val) async {
    _heaterPhase1Flow = val;
  }

  @override
  Future<void> setHeaterPhase2Flow(double val) async {
    _heaterPhase2Flow = val;
  }

  @override
  Future<void> setHeaterPhase2Timeout(double val) async {
    _heaterPhase2Timeout = val;
  }

  @override
  Stream<De1RawMessage> get rawOutStream => throw UnimplementedError();

  @override
  void sendRawMessage(De1RawMessage message) {
    _log.fine("sending raw message: ${message.toJson()}");
  }

  FirmwareUpdateState _firmwareUpdateState = FirmwareUpdateState.idle;

  @override
  FirmwareUpdateState get firmwareUpdateState => _firmwareUpdateState;

  List<bool>? _fwCancelToken;

  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double) onProgress,
  }) {
    if (_firmwareUpdateState != FirmwareUpdateState.idle) {
      throw FirmwareUpdateInProgressException();
    }
    _firmwareUpdateState = FirmwareUpdateState.erasing;
    final token = [false];
    _fwCancelToken = token;
    return _simulateUpdate(fwImage, onProgress, token).whenComplete(() {
      if (identical(_fwCancelToken, token)) {
        _fwCancelToken = null;
        _firmwareUpdateState = FirmwareUpdateState.idle;
      }
    });
  }

  Future<void> _simulateUpdate(
    Uint8List fwImage,
    void Function(double) onProgress,
    List<bool> cancelToken,
  ) async {
    await Future.delayed(const Duration(milliseconds: 100));
    if (cancelToken[0]) throw const FirmwareUpdateCancelledException();

    _firmwareUpdateState = FirmwareUpdateState.uploading;

    final chunkSize = 4096;
    final total = fwImage.length;
    for (int offset = 0; offset < total; offset += chunkSize) {
      if (cancelToken[0]) throw const FirmwareUpdateCancelledException();
      await Future.delayed(const Duration(milliseconds: 20));
      onProgress(offset / total);
    }

    _firmwareUpdateState = FirmwareUpdateState.verifying;
    await Future.delayed(const Duration(milliseconds: 100));
    if (cancelToken[0]) throw const FirmwareUpdateCancelledException();

    onProgress(1.0);
  }

  @override
  Future<void> cancelFirmwareUpload() async {
    if (_firmwareUpdateState == FirmwareUpdateState.idle) return;
    _firmwareUpdateState = FirmwareUpdateState.cancelling;
    _fwCancelToken?[0] = true;
  }

  @override
  Future<void> enableUserPresenceFeature() async {}

  @override
  Future<void> sendUserPresent() async {}

  De1HeaterVoltage _voltage = De1HeaterVoltage.v110;
  @override
  Future<De1HeaterVoltage> getHeaterVoltage() async {
    return _voltage;
  }

  De1RefillKitSettings _de1refillKitSettings = De1RefillKitSettings.auto;
  @override
  Future<De1RefillKitSettings> getRefillKitSettings() async {
    return _de1refillKitSettings;
  }

  @override
  Future<void> setHeaterVoltage(De1HeaterVoltage voltage) async {
    _voltage = voltage;
  }

  @override
  Future<void> setRefillKitSettings(De1RefillKitSettings settings) async {
    _de1refillKitSettings = settings;
  }
}
