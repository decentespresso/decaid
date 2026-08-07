import 'dart:io';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/services/serial/serial_service_android.dart';
import 'package:reaprime/src/services/serial/serial_service_desktop.dart';
import 'package:rxdart/subjects.dart';

DeviceDiscoveryService createSerialService() {
  if (Platform.isIOS) {
    return NoOpSerialService();
  }
  if (Platform.isAndroid) {
    return SerialServiceAndroid();
  }
  return SerialServiceDesktop();
}

class NoOpSerialService implements DeviceDiscoveryService {
  final _devices = BehaviorSubject<List<Device>>.seeded(const <Device>[]);

  @override
  Stream<List<Device>> get devices => _devices.stream;

  @override
  Future<void> initialize() async {}

  @override
  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;
}
