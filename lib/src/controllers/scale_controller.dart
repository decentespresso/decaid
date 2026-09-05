import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/weight_flow_calculator.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/util/kalman_flow_estimator.dart';
import 'package:reaprime/src/util/moving_average.dart';
import 'package:rxdart/rxdart.dart';

class ScaleController {
  Scale? _scale;

  StreamSubscription<ConnectionState>? _scaleConnection;
  StreamSubscription<ScaleSnapshot>? _scaleSnapshot;
  StreamSubscription<ScaleButton>? _scaleButtons;

  final StreamController<ScaleButton> _buttonController =
      StreamController.broadcast();

  String? _lastConnectedDeviceId;
  String? get lastConnectedDeviceId => _lastConnectedDeviceId;
  int _connectionGeneration = 0;
  int get connectionGeneration => _connectionGeneration;
  bool _snapshotSessionActive = false;
  WeightSnapshot? _currentWeightSnapshot;
  WeightSnapshot? get currentWeightSnapshot => _currentWeightSnapshot;

  final Logger log = Logger('ScaleController');

  ScaleController();

  void dispose() {
    _scaleSnapshot?.cancel();
    _scaleSnapshot = null;
    _scaleConnection?.cancel();
    _scaleConnection = null;
    _scaleButtons?.cancel();
    _scaleButtons = null;
    if (!_connectionController.isClosed) {
      _connectionController.close();
    }
    if (!_weightSnapshotController.isClosed) {
      _weightSnapshotController.close();
    }
    if (!_buttonController.isClosed) {
      _buttonController.close();
    }
    _snapshotSessionActive = false;
    _currentWeightSnapshot = null;
  }

  Future<void> connectToScale(Scale scale) async {
    final previous = _scale;
    _onDisconnect();
    if (previous != null && previous.deviceId != scale.deviceId) {
      try {
        if (previous is TransportHandoffScale) {
          await (previous as TransportHandoffScale).disconnectForHandoff();
        } else {
          await previous.disconnect();
        }
      } catch (e) {
        log.warning(
          'Failed to disconnect previous scale ${previous.deviceId}',
          e,
        );
      }
    }
    _scaleSnapshot = scale.currentSnapshot.listen(_processSnapshot);
    try {
      await scale.onConnect();
    } catch (e) {
      log.warning('Scale failed to connect (onConnect threw)', e);
      _scaleSnapshot?.cancel();
      _scaleSnapshot = null;
      _connectionController.add(ConnectionState.disconnected);
      rethrow;
    }
    final state = await scale.connectionState.first;
    if (state != ConnectionState.connected) {
      log.warning('Scale failed to connect (state: ${state.name})');
      _scaleSnapshot?.cancel();
      _scaleSnapshot = null;
      _connectionController.add(ConnectionState.disconnected);
      throw StateError('Scale failed to connect (state: ${state.name})');
    }
    _snapshotSessionActive = true;
    _scale = scale;
    _lastConnectedDeviceId = scale.deviceId;
    _scaleConnection = scale.connectionState.listen(_processConnection);
    _subscribeToButtons(scale);
  }

  Future<void> adoptScale(Scale scale) async {
    final previous = _scale;
    _onDisconnect();
    if (previous != null && previous.deviceId != scale.deviceId) {
      try {
        if (previous is TransportHandoffScale) {
          await (previous as TransportHandoffScale).disconnectForHandoff();
        } else {
          await previous.disconnect();
        }
      } catch (e) {
        log.warning(
          'Failed to disconnect previous scale ${previous.deviceId}',
          e,
        );
      }
    }
    _scaleSnapshot = scale.currentSnapshot.listen(_processSnapshot);
    final state = await scale.connectionState.first;
    if (state != ConnectionState.connected) {
      log.warning('Adopted scale not connected (state: ${state.name})');
      _scaleSnapshot?.cancel();
      _scaleSnapshot = null;
      _connectionController.add(ConnectionState.disconnected);
      throw StateError('Adopted scale not connected (state: ${state.name})');
    }
    _snapshotSessionActive = true;
    _scale = scale;
    _lastConnectedDeviceId = scale.deviceId;
    _scaleConnection = scale.connectionState.listen(_processConnection);
    _subscribeToButtons(scale);
  }

  Stream<ScaleButton> get buttonPresses => _buttonController.stream;

  void _subscribeToButtons(Scale scale) {
    _scaleButtons?.cancel();
    final generation = _connectionGeneration;
    if (scale is! ScaleButtonCapable) {
      _scaleButtons = null;
      return;
    }
    final buttonScale = scale as ScaleButtonCapable;
    _scaleButtons = buttonScale.buttonPresses.listen((button) {
      if (_connectionGeneration == generation) {
        _buttonController.add(button);
      }
    });
  }

  void _onDisconnect() {
    _connectionGeneration++;
    _snapshotSessionActive = false;
    _currentWeightSnapshot = null;
    _scaleSnapshot?.cancel();
    _scaleConnection?.cancel();
    _scaleButtons?.cancel();
    _scale = null;
    _scaleConnection = null;
    _scaleButtons = null;
    _resetDisplayEstimator();
    _kalmanEstimator = null;
    _lastSnapshotTime = null;
    _flowSettleUntil = null;
  }

  Scale connectedScale() {
    if (_scale == null) {
      throw const DeviceNotConnectedException.scale();
    }
    return _scale!;
  }

  final BehaviorSubject<ConnectionState> _connectionController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  Stream<ConnectionState> get connectionState => _connectionController.stream;
  ConnectionState get currentConnectionState => _connectionController.value;

  final StreamController<WeightSnapshot> _weightSnapshotController =
      StreamController.broadcast();

  Stream<WeightSnapshot> get weightSnapshot => _weightSnapshotController.stream;

  static const defaultSmoothingWindow = Duration(milliseconds: 600);
  static const defaultMovingAverageSamples = 10;
  static const minSmoothingWindowMs = 100;
  static const maxSmoothingWindowMs = 2000;
  static const minMovingAverageSamples = 1;
  static const maxMovingAverageSamples = 50;

  Duration _smoothingWindow = defaultSmoothingWindow;
  int _movingAverageSamples = defaultMovingAverageSamples;

  int get flowSmoothingWindowMs => _smoothingWindow.inMilliseconds;
  int get flowSmoothingSamples => _movingAverageSamples;

  MovingAverage weightFlowAverage = MovingAverage(defaultMovingAverageSamples);
  FlowCalculator _flowCalculator = FlowCalculator(
    windowDuration: defaultSmoothingWindow,
  );

  DateTime? _lastSnapshotTime;

  DateTime? _flowSettleUntil;

  KalmanFlowEstimator? _kalmanEstimator;

  Future<void> tare() async {
    final scale = connectedScale();
    await scale.tare();
    _kalmanEstimator?.reset(0.0);
    _resetDisplayEstimator();
    _flowSettleUntil = _lastSnapshotTime?.add(_smoothingWindow);
  }

  void setFlowSmoothing({
    required int windowMs,
    required int movingAverageSamples,
  }) {
    if (windowMs < minSmoothingWindowMs || windowMs > maxSmoothingWindowMs) {
      throw RangeError.range(
        windowMs,
        minSmoothingWindowMs,
        maxSmoothingWindowMs,
        'windowMs',
      );
    }
    if (movingAverageSamples < minMovingAverageSamples ||
        movingAverageSamples > maxMovingAverageSamples) {
      throw RangeError.range(
        movingAverageSamples,
        minMovingAverageSamples,
        maxMovingAverageSamples,
        'movingAverageSamples',
      );
    }
    _smoothingWindow = Duration(milliseconds: windowMs);
    _movingAverageSamples = movingAverageSamples;
    _resetDisplayEstimator();
    _flowSettleUntil = null;
  }

  void _resetDisplayEstimator() {
    _flowCalculator = FlowCalculator(windowDuration: _smoothingWindow);
    weightFlowAverage = MovingAverage(_movingAverageSamples);
  }

  void _processSnapshot(ScaleSnapshot snapshot) {
    if (!_snapshotSessionActive) {
      return;
    }
    _lastSnapshotTime = snapshot.timestamp;

    // Control estimator is always fed the raw weight sample; the signed,
    // control-oriented flow it produces is what shot sequencing consumes.
    _kalmanEstimator ??= KalmanFlowEstimator(initialWeight: snapshot.weight);
    final (_, controlFlow) = _kalmanEstimator!.addSample(
      snapshot.timestamp,
      snapshot.weight,
    );

    // Display estimator stays warm as the fallback when the device provides
    // no flow of its own.
    final rawFlow = _flowCalculator.addSample(
      snapshot.timestamp,
      snapshot.weight,
    );
    weightFlowAverage.add(rawFlow);
    final settling =
        _flowSettleUntil != null &&
        snapshot.timestamp.isBefore(_flowSettleUntil!);
    final displayFlow =
        snapshot.flow ?? (settling ? 0.0 : weightFlowAverage.average);

    final weightSnapshot = WeightSnapshot(
      timestamp: snapshot.timestamp,
      weight: snapshot.weight,
      weightFlow: displayFlow,
      controlWeightFlow: controlFlow,
      battery: snapshot.batteryLevel,
      timerValue: snapshot.timerValue,
      connectionGeneration: _connectionGeneration,
    );
    _currentWeightSnapshot = weightSnapshot;
    _weightSnapshotController.add(weightSnapshot);
  }

  void _processConnection(ConnectionState d) {
    log.info('scale connection update: ${d.name}');
    _connectionController.add(d);
    if (d == ConnectionState.disconnected) {
      _onDisconnect();
    }
  }
}

class WeightSnapshot {
  final DateTime timestamp;
  final double weight;
  final double weightFlow;
  final double controlWeightFlow;
  final int? battery;
  final Duration? timerValue;
  final int connectionGeneration;
  WeightSnapshot({
    required this.timestamp,
    required this.weight,
    required this.weightFlow,
    double? controlWeightFlow,
    this.battery,
    this.timerValue,
    this.connectionGeneration = 0,
  }) : controlWeightFlow = controlWeightFlow ?? weightFlow;

  Map<String, dynamic> toJson() {
    return {
      "timestamp": timestamp.toIso8601String(),
      "weight": weight,
      "weightFlow": weightFlow,
      "battery": battery,
      "timerValue": timerValue?.inMilliseconds,
    };
  }

  factory WeightSnapshot.fromJson(Map<String, dynamic> json) {
    return WeightSnapshot(
      timestamp: DateTime.parse(json["timestamp"]),
      weight: json["weight"],
      weightFlow: json["weightFlow"],
      battery: json["battery"],
      timerValue: json["timerValue"] != null
          ? Duration(milliseconds: json["timerValue"])
          : null,
    );
  }
}
