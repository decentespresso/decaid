import 'dart:async';

import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/simulated_shot_weight_model.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:rxdart/rxdart.dart';

/// Simulated Bengle. Reuses [MockDe1]'s state machine — Bengle's behavior
/// today is functionally identical to a DE1 plus the FW-prelude hook
/// (which mocks bypass entirely, since `MockDe1.updateFirmware` is faked
/// at the public level rather than going through the `_updateFirmware`
/// template that calls `beforeFirmwareUpload`).
///
/// Capability surfaces (cup warmer, integrated scale, LED) are
/// mirrored here.
class MockBengle extends MockDe1 implements BengleInterface, SimulatedDevice {
  MockBengle({super.deviceId = 'MockBengle', bool probeAttached = true}) {
    _probeAttachedSubject = BehaviorSubject<bool>.seeded(probeAttached);
  }

  @override
  String get name => 'MockBengle';

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

  double _cupWarmerTemp = 0.0;

  @override
  Future<void> setCupWarmerTemperature(double celsius) async {
    _cupWarmerTemp = celsius.clamp(0.0, 80.0).toDouble();
  }

  @override
  Future<double> getCupWarmerTemperature() async => _cupWarmerTemp;

  // --- LED strip ---
  /// Cache of the last-set config (not necessarily committed to NVM).
  final BehaviorSubject<LedStripState> _ledState =
      BehaviorSubject<LedStripState>.seeded(const LedStripState());

  /// Simulated "FW NVM" — written by commit, read by reset.
  LedStripState _committedLedState = const LedStripState();

  @override
  Stream<LedStripState> get ledStripState => _ledState.stream;

  @override
  Future<LedStripState> getLedStripState() async => _ledState.value;

  @override
  Future<void> setLedStrip(LedStripState state) async {
    _ledState.add(state);
  }

  @override
  Future<void> commitLedStrip() async {
    _committedLedState = _ledState.value;
  }

  @override
  Future<void> resetLedStrip() async {
    _ledState.add(_committedLedState);
  }

  // --- integrated scale ---
  // Weight synthesis lives in the shared SimulatedShotWeightModel (also used
  // by the standalone MockScale): preinfusion absorbed, first-drops holdback,
  // saturation ramp-in, then weight tracking flow 1:1. BehaviorSubject so a
  // late subscriber (e.g. WS client connecting mid-shot) immediately gets the
  // current weight without waiting for the next flow sample. Closed on
  // onDisconnect; existing subscribers receive `done`.
  final SimulatedShotWeightModel _weightModel = SimulatedShotWeightModel();
  final BehaviorSubject<ScaleSnapshot> _weight = BehaviorSubject();
  StreamSubscription<MachineSnapshot>? _flowSub;

  // --- SAW ---
  /// `0.0` = SAW disabled.
  double _sawTarget = 0.0;
  final BehaviorSubject<double> _sawTargetSubject =
      BehaviorSubject<double>.seeded(0.0);

  // --- milk probe / stop-at-temperature ---
  /// `0.0` = stop disabled.
  double _stopAtTempTarget = 0.0;
  final BehaviorSubject<double> _stopAtTempTargetSubject =
      BehaviorSubject<double>.seeded(0.0);
  late final BehaviorSubject<bool> _probeAttachedSubject;
  final PublishSubject<double> _probeTemperatureSubject =
      PublishSubject<double>();

  /// Simulated probe temperature in °C. Rises during `MachineState.steam`
  /// starting from [_probeStartTemp] at [_probeRiseRate] °C per second.
  static const double _probeStartTemp = 4.0;
  static const double _probeRiseRate = 5.0;
  double _probeTemp = _probeStartTemp;
  DateTime? _lastProbeTickAt;

  @override
  Stream<ScaleSnapshot> get weightSnapshot => _weight.stream;

  @override
  Stream<double> get stopAtWeightTarget => _sawTargetSubject.stream;

  @override
  Future<void> setStopAtWeightTarget(double grams) async {
    _sawTarget = grams.clamp(0.0, 500.0).toDouble();
    if (!_sawTargetSubject.isClosed) {
      _sawTargetSubject.add(_sawTarget);
    }
  }

  @override
  Future<double> getStopAtWeightTarget() async => _sawTarget;

  @override
  Stream<double> get stopAtTemperatureTarget => _stopAtTempTargetSubject.stream;

  @override
  Stream<bool> get probeAttached => _probeAttachedSubject.stream;

  @override
  Stream<double> get probeTemperature => _probeTemperatureSubject.stream;

  @override
  Future<void> setStopAtTemperatureTarget(double celsius) async {
    _stopAtTempTarget = celsius.clamp(0.0, 80.0).toDouble();
    if (!_stopAtTempTargetSubject.isClosed) {
      _stopAtTempTargetSubject.add(_stopAtTempTarget);
    }
  }

  @override
  Future<double> getStopAtTemperatureTarget() async => _stopAtTempTarget;

  /// Test hook: toggle the simulated probe-attached state.
  void setProbeAttached(bool attached) {
    if (!_probeAttachedSubject.isClosed) {
      _probeAttachedSubject.add(attached);
    }
  }

  @override
  Future<void> tareIntegratedScale() async {
    _weightModel.tare();
    _emit();
  }

  void _emit() {
    if (_weight.isClosed) return;
    _weight.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: _weightModel.weight,
        batteryLevel: 100,
      ),
    );
  }

  @override
  Future<void> onConnect() async {
    if (_ledState.isClosed) {
      _ledState.add(const LedStripState());
    }
    await super.onConnect();
    _weightModel.reset();
    _emit();
    _flowSub = currentSnapshot.listen(_integrateFlow);
  }

  void _integrateFlow(MachineSnapshot s) {
    _weightModel
      ..targetVolumeCountStart = targetVolumeCountStart
      ..ingest(s);
    _emit();
    _maybeTriggerSaw(s);
    _tickProbeTemperature(s, s.timestamp);
  }

  /// Synthesises milk-probe temperature during `MachineState.steam`.
  /// Rises linearly from [_probeStartTemp]; resets when steam exits.
  /// If [_stopAtTempTarget] is set and reached, requests `idle` — the
  /// FW-autonomous stop behaviour the real Bengle will perform once
  /// the MMR slot is published.
  void _tickProbeTemperature(MachineSnapshot s, DateTime now) {
    if (!(_probeAttachedSubject.hasValue && _probeAttachedSubject.value)) {
      _lastProbeTickAt = null;
      _probeTemp = _probeStartTemp;
      return;
    }
    if (s.state.state != MachineState.steam) {
      _lastProbeTickAt = null;
      _probeTemp = _probeStartTemp;
      return;
    }
    final last = _lastProbeTickAt;
    _lastProbeTickAt = now;
    if (last == null) return;
    final dtSec = now.difference(last).inMilliseconds / 1000.0;
    if (dtSec <= 0) return;
    _probeTemp += _probeRiseRate * dtSec;
    if (!_probeTemperatureSubject.isClosed) {
      _probeTemperatureSubject.add(_probeTemp);
    }
    if (_stopAtTempTarget > 0.0 && _probeTemp >= _stopAtTempTarget) {
      // ignore: discarded_futures
      requestState(MachineState.idle);
    }
  }

  /// Simulated autonomous SAW. Once the post-tare weight reaches the
  /// active target and the machine is mid-shot (`espresso`/`pouring`),
  /// requests `MachineState.idle` to halt the shot — same effect as the
  /// real Bengle FW would have on its own integrated scale.
  void _maybeTriggerSaw(MachineSnapshot s) {
    if (_sawTarget <= 0.0) return;
    if (s.state.state != MachineState.espresso) return;
    if (s.state.substate != MachineSubstate.preinfusion &&
        s.state.substate != MachineSubstate.pouring) {
      return;
    }
    if (_weightModel.weight >= _sawTarget) {
      // ignore: discarded_futures
      requestState(MachineState.idle);
    }
  }

  @override
  Future<void> onDisconnect() async {
    await _flowSub?.cancel();
    _flowSub = null;
    if (!_ledState.isClosed) {
      await _ledState.close();
    }
    if (!_weight.isClosed) {
      await _weight.close();
    }
    if (!_sawTargetSubject.isClosed) {
      await _sawTargetSubject.close();
    }
    if (!_stopAtTempTargetSubject.isClosed) {
      await _stopAtTempTargetSubject.close();
    }
    if (!_probeAttachedSubject.isClosed) {
      await _probeAttachedSubject.close();
    }
    if (!_probeTemperatureSubject.isClosed) {
      await _probeTemperatureSubject.close();
    }
    await super.onDisconnect();
  }

  @override
  MachineInfo get machineInfo => MachineInfo(
    version: '1.0',
    model: 'Bengle',
    serialNumber: 'mock-bengle',
    groupHeadControllerPresent: true,
    extra: {'voltage': 220, 'refillKit': false},
  );
}
