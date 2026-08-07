import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/hot_water_stop.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

class HotWaterSequencer {
  HotWaterSequencer({
    required De1Controller de1Controller,
    required ScaleController scaleController,
    required SettingsController settingsController,
    DateTime Function()? now,
  }) : _de1 = de1Controller,
       _scale = scaleController,
       _settings = settingsController,
       _now = now ?? DateTime.now {
    _scaleConnected =
        _scale.currentConnectionState == device.ConnectionState.connected;
    _hotWaterSub = _de1.hotWaterData.listen((hw) => _latestHotWater = hw);
    _connectionSub = _scale.connectionState.listen(_onScaleConnection);
    _weightSub = _scale.weightSnapshot.listen(_onWeight);
    _de1Sub = _de1.de1.listen(_onMachineChange);
  }

  final De1Controller _de1;
  final ScaleController _scale;
  final SettingsController _settings;
  final DateTime Function() _now;
  final Logger _log = Logger('HotWaterSequencer');

  static const Duration _tareSettleWindow =
      ScaleController.defaultSmoothingWindow;

  static const Duration _scaleFreshWindow = Duration(seconds: 2);

  static const double _tareConfirmGrams = 3.0;

  static const double _defaultLookaheadSeconds = 0.3;

  StreamSubscription<De1Interface?>? _de1Sub;
  StreamSubscription<MachineSnapshot>? _snapshotSub;
  StreamSubscription<WeightSnapshot>? _weightSub;
  StreamSubscription<device.ConnectionState>? _connectionSub;
  StreamSubscription<HotWaterData>? _hotWaterSub;

  De1Interface? _machine;
  HotWaterData? _latestHotWater;
  MachineState? _latestMachineState;
  WeightSnapshot? _latestWeight;
  DateTime? _lastWeightAt;
  bool _scaleConnected = false;

  bool _tareConfirmed = false;

  HotWaterStopState? _state;
  DateTime? _armedAt;
  DateTime? _tareRequestedAt;

  bool get isArmed => _state != null;

  void _onScaleConnection(device.ConnectionState state) {
    _scaleConnected = state == device.ConnectionState.connected;
    if (!_scaleConnected) _disarm();
  }

  void _onMachineChange(De1Interface? machine) {
    if (identical(_machine, machine)) return;
    _snapshotSub?.cancel();
    _snapshotSub = null;
    _disarm();
    _machine = machine;
    _latestMachineState = null;
    if (machine != null) {
      _snapshotSub = machine.currentSnapshot.listen(_onMachineSnapshot);
    }
  }

  void _onMachineSnapshot(MachineSnapshot snapshot) {
    _latestMachineState = snapshot.state.state;
    if (_state == null) {
      if (snapshot.state.state == MachineState.hotWater) _maybeArm();
    }
    _evaluate();
  }

  void _onWeight(WeightSnapshot weight) {
    _latestWeight = weight;
    _lastWeightAt = _now();
    if (_state == null) return;
    if (!_tareConfirmed && weight.weight <= _tareConfirmGrams) {
      _tareConfirmed = true;
    }
    _evaluate();
  }

  void _maybeArm() {
    if (_machine == null) return;
    if (_settings.gatewayMode == GatewayMode.full) return;
    if (!_settings.stopHotWaterAtWeight) return;
    if (!_scaleConnected) return;
    final hotWater = _latestHotWater;
    if (hotWater == null) return;
    final target = hotWater.volume.toDouble();
    if (target <= 0) return;

    final at = _now();
    _state = HotWaterStopState(
      targetWeight: target,
      configuredFlow: hotWater.flow,
      lookaheadSeconds: _settings.hotWaterFlowMultiplier > 0
          ? _settings.hotWaterFlowMultiplier
          : _defaultLookaheadSeconds,
    );
    _armedAt = at;
    _tareRequestedAt = at;
    _tareConfirmed = false;
    _log.info(
      'Arming hot water stop-at-weight: target ${target.toStringAsFixed(0)} g',
    );
    _scale.tare().catchError(
      (e) => _log.warning('Failed to tare scale for hot water', e),
    );
  }

  void _evaluate() {
    final state = _state;
    if (state == null) return;
    final now = _now();
    final input = HotWaterStopInput(
      machineState: _latestMachineState,
      sinceArmed: _armedAt == null ? Duration.zero : now.difference(_armedAt!),
      tareSettled:
          _tareConfirmed &&
          _tareRequestedAt != null &&
          now.difference(_tareRequestedAt!) >= _tareSettleWindow,
      freshScale:
          _scaleConnected &&
          _lastWeightAt != null &&
          now.difference(_lastWeightAt!) < _scaleFreshWindow,
      weight: _latestWeight?.weight,
      weightFlow: _latestWeight?.controlWeightFlow,
    );

    final decision = nextHotWaterStop(state, input);
    if (decision.action == HotWaterStopAction.clear) {
      _disarm();
      return;
    }
    _state = decision.state;
    if (decision.action == HotWaterStopAction.stop) {
      _log.info(
        'Hot water target ${state.targetWeight.toStringAsFixed(0)} g reached '
        '(weight ${decision.weight.toStringAsFixed(1)} g, '
        'projected ${decision.projectedWeight.toStringAsFixed(1)} g) — stopping',
      );
      final machine = _machine;
      if (machine != null) {
        machine
            .requestState(MachineState.idle)
            .catchError(
              (e) => _log.warning('Failed to stop hot water at weight', e),
            );
      }
    }
  }

  void _disarm() {
    _state = null;
    _armedAt = null;
    _tareRequestedAt = null;
    _tareConfirmed = false;
  }

  Future<void> dispose() async {
    await _de1Sub?.cancel();
    _de1Sub = null;
    await _snapshotSub?.cancel();
    _snapshotSub = null;
    await _weightSub?.cancel();
    _weightSub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    await _hotWaterSub?.cancel();
    _hotWaterSub = null;
  }
}
