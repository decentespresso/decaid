import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/sensor_controller.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_puck_estimator.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_est_sample.dart';

/// Registers [BenglePuckEstimator] with the [SensorController] once the
/// machine actually produces estimator data.
///
/// Registration is driven by the first decoded frame rather than by connection,
/// because `0xA014` is serial/CDC only. A BLE-connected Bengle, a firmware
/// without the observer, or a plain DE1 never emits `[T]`, and none of them
/// should advertise an estimator sensor that would only ever report nothing.
class BenglePuckEstimatorBridge {
  BenglePuckEstimatorBridge({
    required De1Controller de1Controller,
    required SensorController sensorController,
  }) : _de1 = de1Controller,
       _sensors = sensorController {
    _de1Sub = _de1.de1.listen(_onMachineChange);
  }

  final De1Controller _de1;
  final SensorController _sensors;
  final Logger _log = Logger('BenglePuckEstimatorBridge');

  StreamSubscription<De1Interface?>? _de1Sub;
  StreamSubscription<BengleEstSample>? _sampleSub;
  BenglePuckEstimator? _registered;
  BengleInterface? _attachedBengle;

  Future<void> _onMachineChange(De1Interface? device) async {
    if (device is BengleInterface) {
      if (identical(_attachedBengle, device)) return;
      await _detachCurrent();
      _attachedBengle = device;
      _sampleSub = device.puckEstimator.listen(_onSample);
    } else {
      await _detachCurrent();
    }
  }

  Future<void> _onSample(BengleEstSample _) async {
    final bengle = _attachedBengle;
    if (bengle == null || _registered != null) return;
    final sensor = BenglePuckEstimator(bengle: bengle);
    _registered = sensor;
    _log.info('Bengle puck estimator producing data — registering sensor');
    await _sensors.register(sensor);
  }

  Future<void> _detachCurrent() async {
    await _sampleSub?.cancel();
    _sampleSub = null;
    final sensor = _registered;
    if (sensor != null) {
      _registered = null;
      await _sensors.unregister(sensor.deviceId);
    }
    _attachedBengle = null;
  }

  Future<void> dispose() async {
    await _de1Sub?.cancel();
    _de1Sub = null;
    await _detachCurrent();
  }
}
