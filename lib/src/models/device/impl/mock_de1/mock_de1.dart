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

// steam is a placeholder for a future simulation mode.
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

  // Add profile tracking fields
  Profile? _currentProfile;
  int _currentProfileStepIndex = 0;
  double _profileStepElapsedTime = 0.0; // in milliseconds
  double _profileTargetTemperature = 94.0; // Default if no profile
  int _targetVolumeCountStart = 0;

  /// First profile frame that counts toward the shot volume/weight — earlier
  /// frames are preinfusion. Simulated scales gate weight accumulation on it.
  int get targetVolumeCountStart => _targetVolumeCountStart;
  // Smooth transition interpolation: targets at step entry.
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
      // Reset profile tracking when starting espresso
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
      // skipStep: advance to next profile step immediately.
      // ShotSequencer owns the skip decision (weight-based); the mock
      // just advances the step index and continues simulating.
      if (_currentProfileStepIndex < _currentProfile!.steps.length - 1) {
        // Capture current step targets for smooth transition.
        _captureFromTargets(_currentProfile!.steps[_currentProfileStepIndex]);
        _currentProfileStepIndex++;
        _profileStepElapsedTime = 0.0;
        _espressoTickCount = 0; // reset preparingForShot for new step
        _log.fine("skipStep: advanced to step $_currentProfileStepIndex");
      }
      // If already on the last step, skipStep is a no-op — the step
      // will complete naturally via its duration.
      _currentState = MachineState.espresso; // stay in espresso
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
  Future<void> dispose() async {
    // No-op: MockDe1 holds no native resources.
  }

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
    // Use profile target temperature or default
    final targetTemp = _profileTargetTemperature;

    // Faster heating when far from target, slower when close
    double tempChangeRate = 0.5; // degrees per 500ms
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
  // Total elapsed since the shot started (across steps), driving the puck
  // saturation/erosion model and the cold-puck temperature dip.
  double _shotElapsedMs = 0.0;

  MachineSnapshot _simulateEspresso() {
    MachineSubstate substate = _lastSnapshot.state.substate;

    // Determine substate based on pressure
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

    // If we have a profile, use it for simulation
    if (_currentProfile != null && _currentProfile!.steps.isNotEmpty) {
      return _simulateWithProfile();
    }

    // Fallback to original simulation if no profile
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

    // Update elapsed time for current step
    _profileStepElapsedTime += 100; // Timer runs every 100ms

    // Get current step
    final currentStep = _currentProfile!.steps[_currentProfileStepIndex];

    // Check if we should move to next step. Real firmware exits a step when its
    // pressure/flow move-on condition is met, falling back to the step duration;
    // without honouring the exit, a "move on at 4 bar" preinfusion would run its
    // full fallback seconds and the shot would look nothing like a real pull.
    // (Weight/volume exits are driven app-side via requestState(skipStep).)
    final stepDurationMs = currentStep.seconds * 1000;
    final exitMet = _stepExitConditionMet(currentStep);
    if ((_profileStepElapsedTime >= stepDurationMs || exitMet) &&
        _pouringDoneTicks == 0) {
      if (_currentProfileStepIndex < _currentProfile!.steps.length - 1) {
        // Capture current step targets as "from" for smooth transition interpolation.
        _captureFromTargets(currentStep);
        // Move to next step
        _currentProfileStepIndex++;
        _profileStepElapsedTime = 0.0;
        _log.fine("Moving to profile step: $_currentProfileStepIndex");
      } else {
        // Last step is done — trigger pouringDone transition (don't go to idle yet).
        _pouringDoneTicks = 3;
        _log.fine("Profile completed, pouringDone transition");
      }
    }

    // Calculate progress through current step (0.0 to 1.0)
    final stepProgress = stepDurationMs > 0
        ? min(_profileStepElapsedTime / stepDurationMs, 1.0)
        : 0.0;

    _shotElapsedMs += 100;
    final shotSecs = _shotElapsedMs / 1000.0;

    // --- Puck resistance model ---------------------------------------------
    // A fresh puck is porous: during preinfusion water passes with little
    // resistance, so pressure stays low even at high fill flow. As it saturates
    // and packs, resistance climbs to a peak a few seconds into the pour (flow
    // falls out under a held pressure), then slowly erodes/channels so flow
    // creeps back up. This single curve is what makes the coupling below read
    // like a real shot instead of a pressure spike pinned at the ceiling.
    const rDry = 0.10; // bar/(mL/s) — fresh, porous puck
    const rPeak = 4.2; // fully packed
    const rErode = 2.5; // after channeling
    const peakSecs = 12.0; // time from shot start to peak resistance
    const erodeSecs = 16.0; // erosion timescale past the peak
    double resistance;
    if (shotSecs <= peakSecs) {
      // Slow early rise, steepening near breakthrough (cubic).
      final s = shotSecs / peakSecs;
      resistance = rDry + (rPeak - rDry) * s * s * s;
    } else {
      final e = min((shotSecs - peakSecs) / erodeSecs, 1.0);
      resistance = rPeak - (rPeak - rErode) * e;
    }
    resistance *= _puckResistanceMultiplier;

    // --- Temperature: cold-puck dip, then recovery ---
    // Group temp plunges ~16C when water first hits the cold puck (start of
    // preinfusion) and recovers toward the step's target over a few seconds.
    final targetTemp = currentStep.temperature;
    const dipMax = 16.0;
    const dipTauSecs = 3.0;
    // No dip during the ~0.5s prep phase (no water on the puck yet); once water
    // contacts, the group plunges then recovers toward the setpoint.
    final inPrep = _espressoTickCount < 5;
    final contactSecs = max(0.0, shotSecs - 0.5);
    final dip = inPrep ? 0.0 : dipMax * exp(-contactSecs / dipTauSecs);
    final newGroupTemp = targetTemp - dip;
    final newMixTemp = newGroupTemp - 1.0;

    // --- Flow <-> pressure coupling ---
    // Slower than before so flow/pressure ramp over ~1-2s like a real pump/puck
    // rather than snapping to target in one tick.
    const flowResponseRate = 0.35; // per-tick convergence toward flow target
    const pressureDamping = 0.35; // per-tick convergence toward pressure eq

    // Determine flow/pressure targets from step type.
    double targetFlow;
    double targetPressure;
    double stepTargetFlow; // what the profile step prescribes (for snapshot)
    double
    stepTargetPressure; // what the profile step prescribes (for snapshot)
    if (currentStep is ProfileStepPressure) {
      stepTargetPressure = currentStep.pressure;
      stepTargetFlow = 0; // unconstrained in this step
      targetPressure = currentStep.pressure;
      targetFlow = 8.0; // internal: pump max ~8 mL/s
    } else if (currentStep is ProfileStepFlow) {
      stepTargetFlow = currentStep.flow;
      stepTargetPressure = 0; // unconstrained in this step
      targetFlow = currentStep.flow;
      targetPressure = 0; // internal: unconstrained, coupling sets pressure
    } else {
      stepTargetFlow = 4.0;
      stepTargetPressure = 0.0;
      targetFlow = 4.0;
      targetPressure = 0.0;
    }

    // Smooth transition ramps the step's CONTROLLED quantity from its value at
    // step entry to the new target over the step. Only the controlled variable
    // is ramped — ramping a pressure step's internal pump-max flow from 0 would
    // collapse flow (and pressure) at every step boundary.
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

    // Flow responds quickly (pump-driven).
    double newFlow =
        _lastSnapshot.flow +
        (targetFlow - _lastSnapshot.flow) * flowResponseRate;

    if (currentStep is ProfileStepPressure) {
      newFlow = _applyLimiter(newFlow, currentStep.limiter);
    }

    // Pressure lags behind flow (puck-mediated).
    final unboundedPressure = newFlow * resistance;
    double newPressure =
        _lastSnapshot.pressure +
        (unboundedPressure - _lastSnapshot.pressure) * pressureDamping;

    // The pump can only move so much water — real DE1 flow tops out ~8 mL/s.
    const pumpMaxFlow = 8.0;

    // Pressure-step: hold the ceiling, letting flow fall out as the puck packs.
    // On a fresh (low-resistance) puck the flow needed to reach a low target
    // pressure would exceed the pump, so cap it — otherwise a 2 bar preinfusion
    // reads an impossible ~20 mL/s.
    if (currentStep is ProfileStepPressure) {
      if (newPressure >= targetPressure) {
        newPressure = targetPressure;
        newFlow = min(targetPressure / resistance, pumpMaxFlow);
        newFlow = _applyLimiter(newFlow, currentStep.limiter);
      }
    }

    // Clamp flow-step: don't exceed target (pump can't deliver more).
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

    // Physical pressure ceiling (real DE1 tops out ~11 bar; the puck model
    // keeps a well-formed shot far below this).
    const physicalMaxPressure = 11.0;
    if (newPressure > physicalMaxPressure) {
      newPressure = physicalMaxPressure;
      newFlow = min(physicalMaxPressure / resistance, pumpMaxFlow);
    }

    _espressoTickCount++;

    // Derive substate from profile position, not pressure thresholds.
    // First 500ms (5 ticks): preparingForShot.
    // Then: preinfusion (frame < targetVolumeCountStart) or pouring (frame >=).
    MachineSubstate substate;
    if (_pouringDoneTicks > 0) {
      substate = MachineSubstate.pouringDone;
      _pouringDoneTicks--;
      if (_pouringDoneTicks == 0) {
        _simulationType = _SimulationType.idle;
        _currentState = MachineState.idle;
      }
    } else if (_espressoTickCount <= 5) {
      // First ~500ms (5 ticks @ 100ms)
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

  /// Simulated hot-water dispense: flow converges to the configured
  /// hot-water flow and runs until the configured duration elapses (or an
  /// external `requestState(idle)` — e.g. the app's weight-based stop —
  /// ends it). No volume-based auto-stop: like the real DE1 as this app
  /// drives it, weight stops are the app's job, not the machine's.
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
      // Open path to the spout: only a little back-pressure, scaling with flow.
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

  /// Whether the current step's pressure/flow move-on condition is satisfied by
  /// the latest reading. Disabled placeholders (value <= 0, e.g. `flow under 0`)
  /// never fire; weight/volume exits are handled app-side, not here.
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

  /// Snapshot the current step's targets so smooth transitions can interpolate from them.
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

  /// Debug/simulation-only disconnect: emit a disconnected connection
  /// state explicitly. No automatic reconnect (see
  /// `POST /api/v1/debug/machine/disconnect`).
  void simulateDisconnect() {
    _stateTimer?.cancel();
    _connectionState.add(ConnectionState.disconnected);
  }

  bool _chargerOn = false;
  int _steamPurgeMode = 0; // 0 = normal, 1 = two tap stop
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

    // Store the profile and extract target temperature
    _currentProfile = profile;
    _targetVolumeCountStart = profile.targetVolumeCountStart;

    if (profile.steps.isNotEmpty) {
      // Use first step's temperature as target
      _profileTargetTemperature = profile.steps.first.temperature;
      _log.fine("Target temperature set to: $_profileTargetTemperature");

      // Log step durations for debugging
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

    // Reset profile tracking
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

  // Seed `discovered`, not `connected`: a simulated machine is only "connected"
  // once it is actually connected through the controller (onConnect), exactly
  // like a real device. Seeding `connected` made every enabled mock machine
  // (MockDe1 AND MockBengle) self-report connected, so the device list showed
  // two machines connected at once — impossible for real devices.
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
  // TODO: implement rawOutStream
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
