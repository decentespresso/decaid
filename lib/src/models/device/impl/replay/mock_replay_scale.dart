import 'dart:async';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/replay/mock_replay_de1.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

/// The scale companion to [MockReplayDe1]. Instead of integrating flow (as
/// [MockScale] does for the puck simulator), it reports the *recorded* scale
/// weight from the replayed shot, so the weight curve is the genuine one.
class MockReplayScale implements Scale, SimulatedDevice {
  final BehaviorSubject<ConnectionState> _connection = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final StreamController<ScaleSnapshot> _snapshots =
      StreamController.broadcast();

  MockReplayDe1? _machine;
  Timer? _emissionTimer;
  final Stopwatch _timerStopwatch = Stopwatch();
  Duration? _frozenTimerValue;
  bool _timerRunning = false;

  MockReplayScale() {
    _emissionTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _emit(),
    );
  }

  /// Follow [machine] so this scale reports its recorded replay weight.
  void attachMachine(MockReplayDe1 machine) {
    _machine = machine;
  }

  void detachMachine() {
    _machine = null;
  }

  @override
  Stream<ConnectionState> get connectionState => _connection.stream;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshots.stream;

  @override
  String get deviceId => "MockReplayScale";

  @override
  String get name => "Replay Scale";

  @override
  DeviceType get type => DeviceType.scale;

  @override
  DeviceImplementation get implementation => DeviceImplementation.decentScale;

  @override
  TransportType get transportType => TransportType.unknown;

  @override
  Future<void> onConnect() async {
    _connection.add(ConnectionState.connected);
  }

  @override
  disconnect() async {
    _emissionTimer?.cancel();
    _emissionTimer = null;
    _connection.add(ConnectionState.disconnected);
  }

  void _emit() {
    Duration? timerValue;
    if (_timerRunning) {
      timerValue = _timerStopwatch.elapsed;
    } else if (_frozenTimerValue != null) {
      timerValue = _frozenTimerValue;
    }
    _snapshots.add(
      ScaleSnapshot(
        weight: _machine?.replayWeightGrams ?? 0.0,
        timestamp: DateTime.now(),
        batteryLevel: 100,
        timerValue: timerValue,
      ),
    );
  }

  @override
  Future<void> tare() async {}

  @override
  Future<void> sleepDisplay() async {}

  @override
  Future<void> wakeDisplay() async {}

  @override
  Future<void> startTimer() async {
    _frozenTimerValue = null;
    _timerStopwatch
      ..reset()
      ..start();
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
    _timerStopwatch
      ..stop()
      ..reset();
    _frozenTimerValue = null;
    _timerRunning = false;
  }
}
