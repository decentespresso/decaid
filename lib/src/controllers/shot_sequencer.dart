import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/step_exit_arbiter.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/data/shot_state_event.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:rxdart/rxdart.dart';

export 'package:reaprime/src/models/data/shot_state_event.dart'
    show ShotState, ShotDecision, ShotDecisionKind, ShotDecisionReason;

class ShotSequencer {
  final De1Controller de1controller;
  final ScaleController scaleController;
  final PersistenceController persistenceController;
  final Profile targetProfile;

  final Logger _log = Logger("ShotSequencer");

  final bool _bypassSAW;
  final bool _blockOnNoScale;
  final double _weightFlowMultiplier;
  final double _volumeFlowMultiplier;
  final bool _stepExitArbiterEnabled;

  final bool _machineHasAutonomousSAW;

  List<int> skippedSteps = [];
  final StepExitArbiter _stepExitArbiter = StepExitArbiter();
  int _lastProfileFrame = -1;

  int _maxFrameSeen = -1;

  double _accumulatedVolume = 0.0;
  DateTime? _lastVolumeUpdateTime;
  bool _volumeCountingActive = false;

  static const double _settleFlowThreshold = 0.4;
  static const int _settleSampleCount = 10;
  static const double _removalFlowThreshold = 3.0;
  static const double _spikeFlowJump = 3.0;
  static const Duration _stoppingBackstop = Duration(seconds: 4);
  double? _trustedFinalYield;
  bool _stoppingYieldLocked = false;
  int _settleSamples = 0;
  double? _prevStoppingFlow;

  double? get trustedFinalYield => _trustedFinalYield == null
      ? null
      : (_trustedFinalYield! * 10).roundToDouble() / 10;

  ShotSequencer({
    required this.scaleController,
    required this.de1controller,
    required this.persistenceController,
    required this.targetProfile,
    required this.targetYield,
    required bool bypassSAW,
    required bool blockOnNoScale,
    required double weightFlowMultiplier,
    required double volumeFlowMultiplier,
    required bool stepExitArbiterEnabled,
  }) : _bypassSAW = bypassSAW,
       _blockOnNoScale = blockOnNoScale,
       _weightFlowMultiplier = weightFlowMultiplier,
       _volumeFlowMultiplier = volumeFlowMultiplier,
       _stepExitArbiterEnabled = stepExitArbiterEnabled,
       _machineHasAutonomousSAW =
           de1controller.connectedDe1() is BengleInterface {
    _log.info(
      "Initializing ShotSequencer (weightFlowMultiplier: $_weightFlowMultiplier, volumeFlowMultiplier: $_volumeFlowMultiplier, machineHasAutonomousSAW: $_machineHasAutonomousSAW, stepExitArbiterEnabled: $_stepExitArbiterEnabled)",
    );

    _scaleTared = _bypassSAW;

    final scaleConnected =
        scaleController.currentConnectionState ==
        device.ConnectionState.connected;

    if (_blockOnNoScale && !scaleConnected) {
      _emitDecision(
        ShotDecisionKind.abort,
        ShotDecisionReason.noScale,
        details: 'No scale connected, blocking shot',
      );
      de1controller
          .connectedDe1()
          .requestState(MachineState.idle)
          .catchError(
            (error) =>
                _log.warning("Failed to abort shot for blockOnNoScale: $error"),
          );
      return;
    }

    _scaleConnected = scaleConnected;
    _scaleConnectionGeneration = scaleController.connectionGeneration;
    _latestScale = scaleController.currentWeightSnapshot;
    _scaleConnectionSubscription = scaleController.connectionState.listen(
      _onScaleConnection,
    );
    _scaleWeightSubscription = scaleController.weightSnapshot.listen(
      _onScaleWeight,
    );
    _snapshotSubscription = de1controller.connectedDe1().currentSnapshot.listen(
      (machine) {
        _syncScaleConnectionGeneration();
        _processSnapshot(
          ShotSnapshot(machine: machine, scale: _scaleFor(machine)),
        );
      },
      onError: (error) => _log.warning("Error processing DE1 snapshot: $error"),
    );
  }

  void dispose() {
    _log.fine("dispose");
    _snapshotSubscription?.cancel();
    _scaleConnectionSubscription?.cancel();
    _scaleWeightSubscription?.cancel();
    _rawShotDataStream.close();
    _shotDataStream.close();
    _decisionStream.close();
  }

  StreamSubscription<MachineSnapshot>? _snapshotSubscription;
  StreamSubscription<WeightSnapshot>? _scaleWeightSubscription;

  final StreamController<ShotSnapshot> _rawShotDataStream =
      StreamController.broadcast();
  Stream<ShotSnapshot> get rawData => _rawShotDataStream.stream;

  final StreamController<ShotSnapshot> _shotDataStream =
      StreamController.broadcast();

  Stream<ShotSnapshot> get shotData => _shotDataStream.stream;

  final StreamController<bool> _resetCommand = StreamController.broadcast();
  Stream<bool> get resetCommand => _resetCommand.stream;

  final BehaviorSubject<ShotState> _stateStream = BehaviorSubject.seeded(
    ShotState.idle,
  );
  Stream<ShotState> get state => _stateStream.stream;

  final BehaviorSubject<ShotDecision> _decisionStream = BehaviorSubject();
  Stream<ShotDecision> get decisions => _decisionStream.stream;

  static final Logger _decisionLog = Logger('ShotState');

  ShotDecisionReason? _finalStopReason;
  ShotDecisionReason? get finalStopReason => _finalStopReason;

  ShotState get currentState => _state;

  bool get scaleLost => _scaleLost;
  bool get machineHasAutonomousSAW => _machineHasAutonomousSAW;

  void _emitDecision(
    ShotDecisionKind kind,
    ShotDecisionReason reason, {
    String? details,
    Map<String, dynamic>? data,
  }) {
    final message =
        '${kind.name}/${reason.name}: ${details ?? ''}'
        '${data != null ? ' $data' : ''}';
    switch (kind) {
      case ShotDecisionKind.abort:
      case ShotDecisionKind.terminal:
        _decisionLog.warning(message);
      case ShotDecisionKind.finalize:
        _decisionLog.fine(message);
      case ShotDecisionKind.advance:
      case ShotDecisionKind.stop:
        _decisionLog.info(message);
    }
    if (!_decisionStream.isClosed) {
      _decisionStream.add(
        ShotDecision(kind: kind, reason: reason, details: details, data: data),
      );
    }
  }

  DateTime _shotStartTime = DateTime.now();
  DateTime get shotStartTime => _shotStartTime;

  final double targetYield;
  ShotState _state = ShotState.idle;
  bool _scaleLost = false;
  bool _scaleConnected = false;
  bool _continueScaleless = false;
  int _scaleConnectionGeneration = 0;
  WeightSnapshot? _latestScale;
  static const Duration _scaleFreshWindow = Duration(seconds: 2);

  bool _scaleTared = false;
  StreamSubscription<device.ConnectionState>? _scaleConnectionSubscription;

  void _onScaleConnection(device.ConnectionState state) {
    _syncScaleConnectionGeneration();
    final connected = state == device.ConnectionState.connected;
    if (!connected) {
      _latestScale = null;
    }
    _scaleConnected = connected;
    if (!connected) {
      _continueWithoutScale();
    }
  }

  void _onScaleWeight(WeightSnapshot snapshot) {
    _syncScaleConnectionGeneration();
    if (_scaleConnected &&
        !_scaleLost &&
        snapshot.connectionGeneration == _scaleConnectionGeneration &&
        snapshot.connectionGeneration == scaleController.connectionGeneration) {
      _latestScale = snapshot;
    }
  }

  void _syncScaleConnectionGeneration() {
    final generation = scaleController.connectionGeneration;
    if (generation == _scaleConnectionGeneration) {
      return;
    }
    _latestScale = null;
    _scaleConnectionGeneration = generation;
    _continueWithoutScale();
  }

  void _continueWithoutScale() {
    if (_scaleLost ||
        _state == ShotState.idle ||
        _state == ShotState.finished) {
      return;
    }
    _scaleLost = true;
    _continueScaleless = true;
    _log.warning(
      'Scale connection changed during shot (state: ${_state.name}). '
      'Stop-at-weight disabled for remainder of this shot.',
    );
  }

  WeightSnapshot? _scaleFor(MachineSnapshot machine) {
    final scale = _latestScale;
    if (_continueScaleless ||
        _scaleLost ||
        !_scaleConnected ||
        scale == null ||
        scale.connectionGeneration != _scaleConnectionGeneration ||
        scale.connectionGeneration != scaleController.connectionGeneration ||
        machine.timestamp.difference(scale.timestamp).abs() >=
            _scaleFreshWindow) {
      return null;
    }
    return scale;
  }

  void _processSnapshot(ShotSnapshot snapshot) {
    _log.finest("Processing snapshot");

    if (!_scaleTared && snapshot.scale != null) {
      final raw = snapshot.scale!;
      snapshot = snapshot.copyWith(
        scale: WeightSnapshot(
          timestamp: raw.timestamp,
          weight: 0,
          weightFlow: 0,
          battery: raw.battery,
          timerValue: raw.timerValue,
          connectionGeneration: raw.connectionGeneration,
        ),
      );
    }

    final snapshotWithVolume = _updateVolume(snapshot);

    _rawShotDataStream.add(snapshotWithVolume);
    _handleStateTransition(snapshotWithVolume);
    if (dataCollectionEnabled) {
      _shotDataStream.add(snapshotWithVolume);
    }
  }

  ShotSnapshot _updateVolume(ShotSnapshot snapshot) {
    final MachineSnapshot machine = snapshot.machine;
    final int currentFrame = machine.profileFrame;

    if (_volumeCountingActive &&
        currentFrame >= targetProfile.targetVolumeCountStart) {
      final now = snapshot.machine.timestamp;

      if (_lastVolumeUpdateTime != null) {
        final timeDelta =
            now.difference(_lastVolumeUpdateTime!).inMilliseconds / 1000.0;

        final volumeDelta = machine.flow * timeDelta;
        _accumulatedVolume += volumeDelta;

        _log.finest(
          "Volume update: flow=${machine.flow} ml/s, delta=${timeDelta}s, "
          "volumeDelta=${volumeDelta}ml, total=${_accumulatedVolume}ml",
        );
      }

      _lastVolumeUpdateTime = now;
    }

    return snapshot.copyWith(volume: _accumulatedVolume);
  }

  bool dataCollectionEnabled = false;
  Future<void>? _stoppingStateFuture;

  void _handleStateTransition(ShotSnapshot snapshot) {
    final MachineSnapshot machine = snapshot.machine;
    final WeightSnapshot? scale = snapshot.scale;

    _log.finest(
      "recv: ${machine.state.substate.name}, ${machine.state.state.name}",
    );

    _log.finest("State in: ${_state.name}");

    if (machine.state.state == MachineState.error &&
        _state != ShotState.idle &&
        _state != ShotState.finished) {
      _finalStopReason ??= ShotDecisionReason.error;
      _emitDecision(
        ShotDecisionKind.terminal,
        ShotDecisionReason.error,
        details: 'Machine entered error state (${machine.state.substate.name})',
        data: {'substate': machine.state.substate.name},
      );
      _volumeCountingActive = false;
      dataCollectionEnabled = false;
      _state = ShotState.finished;
      _stateStream.add(_state);
      return;
    }

    switch (_state) {
      case ShotState.idle:
        if (machine.state.state == MachineState.espresso &&
            machine.state.substate == MachineSubstate.preparingForShot) {
          _resetCommand.add(true);
          _shotStartTime = DateTime.now();

          _accumulatedVolume = 0.0;
          _lastVolumeUpdateTime = null;
          _volumeCountingActive = false;
          _trustedFinalYield = null;
          _stoppingYieldLocked = false;
          _settleSamples = 0;
          _prevStoppingFlow = null;
          skippedSteps.clear();
          _stepExitArbiter.reset();
          _lastProfileFrame = -1;
          _maxFrameSeen = -1;
          _finalStopReason = null;

          if (scale == null) {
            _continueScaleless = true;
            _log.info(
              'No fresh scale sample at shot start; continuing scaleless',
            );
          }

          if (_bypassSAW == false && scale != null && !_scaleLost) {
            _log.info(
              "Machine getting ready. Taring scale and resetting timer...",
            );
            scaleController.tare().catchError(
              (e) => _log.warning("Failed to tare scale at shot start", e),
            );
            scaleController.connectedScale().resetTimer();
          }
          _state = ShotState.preheating;
          _stateStream.add(_state);
          dataCollectionEnabled = true;
        }
        break;

      case ShotState.preheating:
        if (machine.state.state != MachineState.espresso) {
          final intent = de1controller.consumeStopIntent();
          _emitDecision(
            ShotDecisionKind.abort,
            intent ?? ShotDecisionReason.machineEnded,
            details: 'Shot aborted during preheat, before the pour began',
          );
          break;
        }
        if (machine.state.substate == MachineSubstate.preinfusion ||
            machine.state.substate == MachineSubstate.pouring) {
          if (scale == null) {
            _continueScaleless = true;
          }
          if (_bypassSAW == false && scale != null && !_scaleLost) {
            _log.info("Taring scale again and starting timer.");
            scaleController.tare().catchError(
              (e) => _log.warning("Failed to tare scale for pour", e),
            );
            scaleController.connectedScale().startTimer();
            _scaleTared = true;
          }

          _volumeCountingActive = true;
          _log.info(
            "Volume counting activated. Will start from frame ${targetProfile.targetVolumeCountStart}",
          );

          _state = ShotState.pouring;
          _stateStream.add(_state);
        }
        break;

      case ShotState.pouring:
        _trackFrameAdvance(machine.profileFrame);
        if (_bypassSAW == false && scale != null && !_scaleLost) {
          double currentWeight = scale.weight;
          double weightFlow = scale.controlWeightFlow;
          double projectedWeight =
              currentWeight + (weightFlow * _weightFlowMultiplier);

          _handleStepWeightExit(machine.profileFrame, projectedWeight, machine);
          if (!_machineHasAutonomousSAW &&
              targetYield > 0 &&
              projectedWeight >= targetYield) {
            _finalStopReason = ShotDecisionReason.targetWeight;
            _emitDecision(
              ShotDecisionKind.stop,
              ShotDecisionReason.targetWeight,
              details:
                  'Target weight ${targetYield}g reached '
                  '(projected: $projectedWeight). Stopping shot.',
              data: {
                'targetYield': targetYield,
                'projectedWeight': projectedWeight,
              },
            );
            de1controller.connectedDe1().requestState(MachineState.idle);
            _enterStopping(scale);
            break;
          }
        }
        if (!_bypassSAW &&
            !_machineHasAutonomousSAW &&
            (scale == null || _scaleLost) &&
            (targetProfile.targetVolume ?? 0) > 0) {
          final projectedVolume =
              _accumulatedVolume + (machine.flow * _volumeFlowMultiplier);
          if (projectedVolume > targetProfile.targetVolume!) {
            _finalStopReason = ShotDecisionReason.targetVolume;
            _emitDecision(
              ShotDecisionKind.stop,
              ShotDecisionReason.targetVolume,
              details:
                  'Target volume ${targetProfile.targetVolume}ml reached '
                  '(projected: $projectedVolume). Stopping shot.',
              data: {
                'targetVolume': targetProfile.targetVolume,
                'projectedVolume': projectedVolume,
              },
            );
            de1controller.connectedDe1().requestState(MachineState.idle);
            _enterStopping(scale);
            break;
          }
        }
        if (machine.state.substate == MachineSubstate.pouringDone ||
            machine.state.substate == MachineSubstate.idle) {
          final intent = de1controller.consumeStopIntent();
          final reason = intent ?? ShotDecisionReason.machineEnded;
          _finalStopReason ??= reason;
          _emitDecision(
            ShotDecisionKind.stop,
            reason,
            details: switch (reason) {
              ShotDecisionReason.apiStop => 'Shot stopped via REST API request',
              ShotDecisionReason.appStop => 'Shot stopped from the app UI',
              _ =>
                'Machine reported shot end '
                    '(${machine.state.substate.name})',
            },
          );
          _enterStopping(scale);
        }
        break;

      case ShotState.stopping:
        _volumeCountingActive = false;
        if (_bypassSAW == false && scale != null && !_scaleLost) {
          scaleController.connectedScale().stopTimer();
        }

        _refineStoppingYield(scale);
        if (_stoppingYieldLocked) {
          _log.info(
            "Final yield ${trustedFinalYield}g locked. "
            "Final volume: ${_accumulatedVolume}ml",
          );
          _finishStopping();
          break;
        }

        _stoppingStateFuture ??= Future.delayed(_stoppingBackstop, () {
          if (_state == ShotState.stopping) {
            _emitDecision(
              ShotDecisionKind.finalize,
              ShotDecisionReason.stoppingBackstop,
              details:
                  'Stopping backstop fired. '
                  'Final volume: ${_accumulatedVolume}ml',
              data: {'finalVolume': _accumulatedVolume},
            );
            _finishStopping();
          }
        });
        break;

      case ShotState.finished:
        dataCollectionEnabled = false;
        _stoppingStateFuture = null;
        _state = ShotState.idle;
        _stateStream.add(_state);
        break;
    }
    _log.finest("State out: ${_state.name}");
  }

  void _trackFrameAdvance(int profileFrame) {
    if (profileFrame != _lastProfileFrame) {
      _stepExitArbiter.onFrameAdvanced(profileFrame);
      _lastProfileFrame = profileFrame;
    }
    if (_maxFrameSeen < 0) {
      _maxFrameSeen = profileFrame;
      return;
    }
    if (profileFrame <= _maxFrameSeen) {
      return;
    }
    for (var frame = _maxFrameSeen; frame < profileFrame; frame++) {
      if (skippedSteps.contains(frame)) {
        continue;
      }
      _emitDecision(
        ShotDecisionKind.advance,
        ShotDecisionReason.profileAdvance,
        details: 'Firmware advanced from frame $frame to ${frame + 1}',
        data: {'fromFrame': frame, 'toFrame': frame + 1},
      );
    }
    _maxFrameSeen = profileFrame;
  }

  void _handleStepWeightExit(
    int profileFrame,
    double projectedWeight,
    MachineSnapshot machineSnapshot,
  ) {
    if (profileFrame < 0 || profileFrame >= targetProfile.steps.length) {
      return;
    }

    final step = targetProfile.steps[profileFrame];
    final stepExitWeight = step.weight;
    if (stepExitWeight == null || stepExitWeight <= 0) {
      return;
    }

    if (skippedSteps.contains(profileFrame)) {
      return;
    }

    if (projectedWeight < stepExitWeight) {
      return;
    }

    if (_stepExitArbiterEnabled && step.exit != null) {
      final verdict = _stepExitArbiter.evaluate(
        profileFrame: profileFrame,
        exit: step.exit!,
        currentPressure: machineSnapshot.pressure,
        currentFlow: machineSnapshot.flow,
      );
      if (verdict == StepExitVerdict.defer) {
        return;
      }
    }

    _emitDecision(
      ShotDecisionKind.advance,
      ShotDecisionReason.profileSkip,
      details:
          'Step weight ${stepExitWeight}g reached '
          '(projected: $projectedWeight), skipping frame $profileFrame',
      data: {
        'frame': profileFrame,
        'stepExitWeight': stepExitWeight,
        'projectedWeight': projectedWeight,
      },
    );
    skippedSteps.add(profileFrame);
    de1controller.connectedDe1().requestState(MachineState.skipStep);
  }

  void _enterStopping(WeightSnapshot? scale) {
    _latchTrustedFinalYield(scale);
    dataCollectionEnabled = false;
    _state = _trustedFinalYield != null
        ? ShotState.stopping
        : ShotState.finished;
    _stateStream.add(_state);
  }

  void _latchTrustedFinalYield(WeightSnapshot? scale) {
    final weight = scale?.weight;
    if (weight == null || weight <= 0 || !weight.isFinite) return;
    _trustedFinalYield = weight;
  }

  void _refineStoppingYield(WeightSnapshot? scale) {
    if (_stoppingYieldLocked) return;
    final weight = scale?.weight;
    if (weight == null || weight <= 0 || !weight.isFinite) return;
    final flow = scale!.controlWeightFlow.isFinite
        ? scale.controlWeightFlow
        : 0.0;
    final prevFlow = _prevStoppingFlow;
    _prevStoppingFlow = flow;

    if (flow < -_removalFlowThreshold) {
      _stoppingYieldLocked = true;
      return;
    }
    if (prevFlow != null && flow > prevFlow + _spikeFlowJump) {
      _stoppingYieldLocked = true;
      return;
    }

    if (_trustedFinalYield == null || weight > _trustedFinalYield!) {
      _trustedFinalYield = weight;
    }

    if (flow.abs() < _settleFlowThreshold) {
      if (++_settleSamples >= _settleSampleCount) {
        _trustedFinalYield = weight;
        _stoppingYieldLocked = true;
      }
    } else {
      _settleSamples = 0;
    }
  }

  void _finishStopping() {
    _state = ShotState.finished;
    _stateStream.add(_state);
  }
}
