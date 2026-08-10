import 'dart:async';
import 'dart:math';

import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/simulated_shot_weight_model.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

class MockScale implements Scale, SimulatedDevice {
  // Seed `discovered`, not `connected`: a simulated scale is only "connected"
  // once it is actually connected through the controller (onConnect), like a
  // real scale. Seeding `connected` made Mock Scale self-report connected even
  // when it wasn't the active scale, so the device list could show two scales
  // connected at once.
  final BehaviorSubject<ConnectionState> _connectionSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);

  @override
  Stream<ConnectionState> get connectionState => _connectionSubject.stream;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshotStream.stream;

  // Space-free id so it matches the `MockScale` token used by
  // preferredScaleId dart-defines, sb-dev's `--connect-scale` flag, and
  // remembered-device records. The human-facing `name` keeps the space.
  @override
  String get deviceId => "MockScale";

  @override
  DeviceImplementation get implementation => DeviceImplementation.decentScale;

  @override
  TransportType get transportType => TransportType.unknown;

  @override
  disconnect() async {
    simulateDisconnect();
  }

  @override
  String get name => "Mock Scale";

  @override
  Future<void> onConnect() async {
    _connectionSubject.add(ConnectionState.connected);
  }

  @override
  Future<void> tare() async {
    _model.tare();
    // Real scales report an exact 0.0 right after tare.
    _emittedWeight = 0.0;
  }

  @override
  Future<void> sleepDisplay() async {}

  @override
  Future<void> wakeDisplay() async {}

  @override
  DeviceType get type => DeviceType.scale;

  final StreamController<ScaleSnapshot> _snapshotStream =
      StreamController.broadcast();

  // Weight follows the simulated machine's flow (when one is attached via
  // [attachMachine]) through the shared shot-weight model, so a simulated
  // shot produces a believable curve: nothing at idle, first-drops lag,
  // then weight tracking flow. Without a machine the scale reads a flat ~0.
  //
  // Like real scale firmware, the emitted stream is stability-filtered:
  // while the underlying weight is at rest the reported value holds
  // perfectly still (no raw load-cell noise broadcast to clients); only a
  // change past the deadband — water landing in the cup, a tare — moves
  // the reading, and each movement carries a hair of load-cell jitter.
  static const double _jitterGrams = 0.03;
  static const double _stabilityDeadband = 0.05;
  double _emittedWeight = 0.0;
  final SimulatedShotWeightModel _model = SimulatedShotWeightModel();
  final Random _random = Random();
  MockDe1? _machine;
  StreamSubscription<MachineSnapshot>? _machineSub;
  final Stopwatch _timerStopwatch = Stopwatch();
  Duration? _frozenTimerValue;
  bool _timerRunning = false;
  bool _stalled = false;
  Timer? _emissionTimer;

  MockScale() {
    _startEmission();
  }

  /// Follow [machine]'s simulated flow so the weight responds to its shots.
  /// Idempotent for the same machine; switches cleanly to a new one.
  void attachMachine(MockDe1 machine) {
    if (identical(machine, _machine)) return;
    _machineSub?.cancel();
    _machine = machine;
    _machineSub = machine.currentSnapshot.listen((s) {
      _model
        ..targetVolumeCountStart = machine.targetVolumeCountStart
        ..ingest(s);
    });
  }

  /// Stop following the machine. The reading freezes at its current value.
  void detachMachine() {
    _machineSub?.cancel();
    _machineSub = null;
    _machine = null;
  }

  void _startEmission() {
    _emissionTimer?.cancel();
    _emissionTimer = Timer.periodic(Duration(milliseconds: 200), (_) {
      if (_stalled) return;
      Duration? timerValue;
      if (_timerRunning) {
        timerValue = _timerStopwatch.elapsed;
      } else if (_frozenTimerValue != null) {
        timerValue = _frozenTimerValue;
      }
      final weight = _model.weight;
      if ((weight - _emittedWeight).abs() >= _stabilityDeadband) {
        final jitter = (_random.nextDouble() - 0.5) * 2 * _jitterGrams;
        _emittedWeight = weight + jitter;
      }
      _snapshotStream.add(
        ScaleSnapshot(
          weight: _emittedWeight,
          timestamp: DateTime.now(),
          batteryLevel: 100,
          timerValue: timerValue,
        ),
      );
    });
  }

  /// Stop emitting weight snapshots. Scale stays "connected".
  void simulateDataStall() {
    _stalled = true;
  }

  /// Resume weight emission after a stall.
  void simulateResume() {
    _stalled = false;
  }

  /// Emit disconnected state and stop weight emission.
  void simulateDisconnect() {
    _stalled = true;
    _emissionTimer?.cancel();
    _emissionTimer = null;
    detachMachine();
    _connectionSubject.add(ConnectionState.disconnected);
  }

  @override
  Future<void> startTimer() async {
    _frozenTimerValue = null;
    _timerStopwatch.start();
    _timerRunning = true;
  }

  @override
  Future<void> stopTimer() async {
    _timerStopwatch.stop();
    _frozenTimerValue = _timerStopwatch.elapsed;
    _timerRunning = false;
  }

  @override
  Future<void> resetTimer() async {
    _timerStopwatch.stop();
    _timerStopwatch.reset();
    _frozenTimerValue = null;
    _timerRunning = false;
  }
}
