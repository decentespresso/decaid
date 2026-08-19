import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:rxdart/rxdart.dart';

class SensorController {
  final DeviceController _deviceController;

  final Map<String, Sensor> _discovered = {};
  final Map<String, Sensor> _bridgeRegistered = {};
  final BehaviorSubject<Map<String, Sensor>> _sensorRegistry =
      BehaviorSubject.seeded(const {});

  final Logger _log = Logger("SensorController");

  StreamSubscription<List<Device>>? _deviceStreamSubscription;

  SensorController({required DeviceController controller})
    : _deviceController = controller {
    _deviceStreamSubscription = _deviceController.deviceStream.listen(
      _processDevices,
    );
  }

  Future<void> _processDevices(List<Device> devices) async {
    final sensors = devices.whereType<Sensor>().toList();
    _log.info("received sensors: $sensors");
    _discovered
      ..clear()
      ..addEntries(sensors.map((s) => MapEntry(s.deviceId, s)));
    _publishSensors();
    await Future.wait(sensors.map((s) => s.onConnect()));
  }

  Future<void> register(Sensor sensor) async {
    final id = sensor.deviceId;
    final existing = _bridgeRegistered[id];
    if (existing != null && !identical(existing, sensor)) {
      await existing.disconnect();
    }
    _bridgeRegistered[id] = sensor;
    if (!identical(existing, sensor)) {
      _publishSensors();
      await sensor.onConnect();
    }
  }

  Future<void> unregister(String deviceId) async {
    final removed = _bridgeRegistered.remove(deviceId);
    if (removed != null) {
      _publishSensors();
      await removed.disconnect();
    }
  }

  Map<String, Sensor> get sensors =>
      Map.unmodifiable({..._discovered, ..._bridgeRegistered});

  Stream<Map<String, Sensor>> get sensorRegistry => _sensorRegistry.stream;

  void _publishSensors() => _sensorRegistry.add(sensors);

  void dispose() {
    _deviceStreamSubscription?.cancel();
    _deviceStreamSubscription = null;
    _sensorRegistry.close();
  }
}
