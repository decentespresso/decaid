import 'dart:async';

import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/cup_warmer.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/simulated_shot_weight_model.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:rxdart/rxdart.dart';

class MockBengle extends MockDe1 implements BengleInterface, SimulatedDevice {
  MockBengle({
    super.deviceId = 'MockBengle',
    bool probeAttached = true,
    this.supportsCurrentFirmwareSurface = true,
  }) {
    _probeAttachedSubject = BehaviorSubject<bool>.seeded(probeAttached);
  }

  /// False simulates Bengle firmware predating the post-0x00803880 MMR
  /// surface (scale cal, LED palette, cup-warmer mode, schedule, pre-warm):
  /// the machine is then firmware-incompatible, not feature-reduced.
  final bool supportsCurrentFirmwareSurface;

  @override
  String get name => 'MockBengle';

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

  @override
  bool get supportsCurrentBengleFirmwareSurface =>
      supportsCurrentFirmwareSurface;

  ScaleCalibrationState _calState = const ScaleCalibrationState(
    step: ScaleCalibrationStep.idle,
    detectedCell: ScaleCalibrationCell.none,
    subState: ScaleCalibrationSubState.settling,
    secondsRemaining: 0,
    status: ScaleCalibrationStatus.none,
  );

  @override
  Future<ScaleCalibrationState> getScaleCalibrationState() async => _calState;

  @override
  Future<bool> startScaleCalibration(
    ScaleCalibrationCommand command, {
    double? weightGrams,
  }) async {
    switch (command) {
      case ScaleCalibrationCommand.abort:
        _calState = const ScaleCalibrationState(
          step: ScaleCalibrationStep.idle,
          detectedCell: ScaleCalibrationCell.none,
          subState: ScaleCalibrationSubState.settling,
          secondsRemaining: 0,
          status: ScaleCalibrationStatus.none,
        );
      case ScaleCalibrationCommand.zero:
        _calState = const ScaleCalibrationState(
          step: ScaleCalibrationStep.zeroing,
          detectedCell: ScaleCalibrationCell.none,
          subState: ScaleCalibrationSubState.settling,
          secondsRemaining: 15,
          status: ScaleCalibrationStatus.none,
        );
      case ScaleCalibrationCommand.latch:
        _calState = const ScaleCalibrationState(
          step: ScaleCalibrationStep.calLatch,
          detectedCell: ScaleCalibrationCell.none,
          subState: ScaleCalibrationSubState.settling,
          secondsRemaining: 15,
          status: ScaleCalibrationStatus.none,
        );
    }
    return true;
  }

  double _cupWarmerTemp = 0.0;
  bool _cupWarmerEnabled = false;
  bool _preheatEnabled = false;
  int _preheatLeadMinutes = 30;

  @override
  Future<void> setCupWarmerTemperature(double celsius) async {
    _cupWarmerTemp = celsius.clamp(0.0, 80.0).toDouble();
  }

  @override
  Future<double> getCupWarmerTemperature() async => _cupWarmerTemp;

  @override
  Future<void> setCupWarmerEnabled(bool enabled) async {
    _cupWarmerEnabled = enabled;
  }

  @override
  Future<bool> getCupWarmerEnabled() async => _cupWarmerEnabled;

  @override
  Future<double?> getCupWarmerCurrentTemperature() async {
    // Mock: the NTC reads a temperature once the warmer has been enabled.
    return _cupWarmerEnabled ? 42.0 : null;
  }

  @override
  Future<void> setCupWarmerPreheat({
    required bool enabled,
    required int leadMinutes,
  }) async {
    _preheatEnabled = enabled;
    _preheatLeadMinutes = leadMinutes.clamp(0, 120);
  }

  @override
  Future<CupWarmerPreheatState> getCupWarmerPreheatState() async =>
      CupWarmerPreheatState(
        enabled: _preheatEnabled,
        leadMinutes: _preheatLeadMinutes,
        active: _preheatEnabled && _cupWarmerTemp > 0,
      );

  int _inactivitySleepTimeout = 0;
  int? _pushedClockSeconds;
  List<FirmwareWakeWindow> _pushedWindows = const [];

  @override
  Future<void> setInactivitySleepTimeout(int minutes) async {
    _inactivitySleepTimeout = minutes.clamp(0, 240);
  }

  /// Last value written via [setInactivitySleepTimeout].
  int get inactivitySleepTimeout => _inactivitySleepTimeout;

  @override
  Future<void> pushFirmwareWakeSchedule({
    required int secondsSinceSundayLocal,
    required List<FirmwareWakeWindow> windows,
  }) async {
    _pushedClockSeconds = secondsSinceSundayLocal;
    _pushedWindows = windows;
  }

  /// Clock value recorded by [pushFirmwareWakeSchedule].
  int? get pushedClockSeconds => _pushedClockSeconds;

  /// Recorded by [pushFirmwareWakeSchedule] for scenario assertions.
  List<FirmwareWakeWindow> get pushedWakeWindows => _pushedWindows;

  final BehaviorSubject<LedStripState?> _ledState =
      BehaviorSubject<LedStripState?>.seeded(null);

  @override
  Stream<LedStripState?> get ledStripState => _ledState.stream;

  @override
  Future<LedStripState?> getLedStripState() async => _ledState.value;

  @override
  Future<void> setLedStrip(LedStripState state) async {
    // Mirror the firmware: 8 bits per RGB channel are stored, and the
    // switch palette is derived from the front strip (black falls back to
    // the product defaults), never independent.
    Color16 quantize(Color16 color) =>
        Color16(color.red & 0xFF00, color.green & 0xFF00, color.blue & 0xFF00);

    ZoneLedState quantizeZone(ZoneLedState zone) => ZoneLedState(
      awake: quantize(zone.awake),
      sleeping: quantize(zone.sleeping),
    );

    ZoneLedState derive(ZoneLedState strip, int defaultRgb) {
      Color16 fallback(int rgb) => Color16(
        ((rgb >> 16) & 0xFF) << 8,
        ((rgb >> 8) & 0xFF) << 8,
        (rgb & 0xFF) << 8,
      );

      return ZoneLedState(
        awake: strip.awake == Color16.off ? fallback(0xFFF0C8) : strip.awake,
        sleeping: strip.sleeping == Color16.off
            ? fallback(0x555043)
            : strip.sleeping,
      );
    }

    final frontStrip = quantizeZone(state.frontStrip);
    final backStrip = quantizeZone(state.backStrip);
    _ledState.add(
      LedStripState(
        frontStrip: frontStrip,
        backStrip: backStrip,
        frontSwitch: derive(frontStrip, 0),
      ),
    );
  }

  @override
  Future<void> commitLedStrip() async {}

  @override
  Future<LedStripState?> resetLedStrip() async => _ledState.value;

  final SimulatedShotWeightModel _weightModel = SimulatedShotWeightModel();
  final BehaviorSubject<ScaleSnapshot> _weight = BehaviorSubject();
  StreamSubscription<MachineSnapshot>? _flowSub;

  double _sawTarget = 0.0;
  final BehaviorSubject<double> _sawTargetSubject =
      BehaviorSubject<double>.seeded(0.0);

  double _stopAtTempTarget = 0.0;
  final BehaviorSubject<double> _stopAtTempTargetSubject =
      BehaviorSubject<double>.seeded(0.0);
  late final BehaviorSubject<bool> _probeAttachedSubject;
  final PublishSubject<double> _probeTemperatureSubject =
      PublishSubject<double>();

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
    _sawTarget = grams.clamp(0.0, 10000.0).toDouble();
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
    _stopAtTempTarget = celsius.clamp(0.0, 85.0).toDouble();
    if (!_stopAtTempTargetSubject.isClosed) {
      _stopAtTempTargetSubject.add(_stopAtTempTarget);
    }
  }

  @override
  Future<double> getStopAtTemperatureTarget() async => _stopAtTempTarget;

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
      _ledState.add(null);
    }
    // Simulate firmware hydration with a deterministic non-black palette.
    _ledState.add(
      const LedStripState(
        frontStrip: ZoneLedState(
          awake: Color16(0xFF00, 0xF000, 0x8000),
          sleeping: Color16(0x3000, 0x2000, 0x1000),
        ),
        backStrip: ZoneLedState(
          awake: Color16(0xFF00, 0xF000, 0x8000),
          sleeping: Color16(0x3000, 0x2000, 0x1000),
        ),
        frontSwitch: ZoneLedState(
          awake: Color16(0xFF00, 0xF000, 0x8000),
          sleeping: Color16(0x3000, 0x2000, 0x1000),
        ),
      ),
    );
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
    extra: {
      'voltage': 220,
      'refillKit': false,
      'bengleFirmwareSurface': supportsCurrentBengleFirmwareSurface
          ? 'current'
          : 'outdated',
    },
  );
}
