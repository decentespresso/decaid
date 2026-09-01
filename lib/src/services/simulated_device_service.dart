import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_grinder/mock_grinder.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/impl/replay/mock_replay_de1.dart';
import 'package:reaprime/src/models/device/impl/sensor/mock/mock_debug_port.dart';
import 'package:reaprime/src/models/device/impl/sensor/mock/mock_sensor_basket.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/services/simulated_shot_library.dart';
import 'package:reaprime/src/settings/settings_service.dart';

class SimulatedDeviceService
    with ChangeNotifier
    implements DeviceDiscoveryService {
  SimulatedDeviceService({SimulatedShotLibrary? replayLibrary})
    : _replayLibrary = replayLibrary ?? SimulatedShotLibrary();

  final SimulatedShotLibrary _replayLibrary;

  final Map<String, Device> _devices = {};

  final StreamController<List<Device>> _deviceStreamController =
      StreamController.broadcast();

  Set<SimulatedDevicesTypes> enabledDevices = {};

  @override
  Stream<List<Device>> get devices => _deviceStreamController.stream;

  @override
  Future<void> initialize() async {}

  int scanCount = 0;

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    if (enabledDevices.isEmpty) {
      return;
    }
    if (enabledDevices.contains(SimulatedDevicesTypes.machine)) {
      _devices.putIfAbsent("MockDe1", () => MockDe1());
    } else {
      _devices.remove("MockDe1");
    }
    if (enabledDevices.contains(SimulatedDevicesTypes.bengle)) {
      _devices.putIfAbsent("MockBengle", () => MockBengle());
    } else {
      _devices.remove("MockBengle");
    }
    if (enabledDevices.contains(SimulatedDevicesTypes.scale)) {
      _devices.putIfAbsent("MockScale", () => MockScale());
    } else {
      _devices.remove("MockScale");
    }
    if (enabledDevices.contains(SimulatedDevicesTypes.sensor)) {
      _devices.putIfAbsent("MockSensorBasket", () => MockSensorBasket());
      _devices.putIfAbsent("MockDebugPort", () => MockDebugPort());
    } else {
      _devices.remove("MockSensorBasket");
      _devices.remove("MockDebugPort");
    }
    if (enabledDevices.contains(SimulatedDevicesTypes.replay)) {
      await _replayLibrary.ensureLoaded();
      _devices.putIfAbsent(
        "MockReplayDe1",
        () => MockReplayDe1(library: _replayLibrary),
      );
    } else {
      _devices.remove("MockReplayDe1");
    }
    if (enabledDevices.contains(SimulatedDevicesTypes.grinder)) {
      _devices.putIfAbsent("MockGrinder", () => MockGrinder());
    } else {
      _devices.remove("MockGrinder");
    }
    final scale = _devices["MockScale"];
    if (scale is MockScale) {
      final machine = _devices["MockDe1"] ?? _devices["MockBengle"];
      if (machine is MockDe1) {
        scale.attachMachine(machine);
      } else {
        scale.detachMachine();
      }
    }
    _deviceStreamController.add(_devices.values.toList());
    notifyListeners();
    scanCount++;
  }
}
