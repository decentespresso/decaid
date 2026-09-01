import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

enum DeviceType { machine, scale, sensor, grinder }

abstract class Device {
  String get deviceId;
  String get name;
  DeviceType get type;

  DeviceImplementation get implementation;

  TransportType get transportType;

  Future<void> onConnect();

  Future<void> disconnect();

  Stream<ConnectionState> get connectionState;
}

enum ConnectionState {
  discovered,
  connecting,
  connected,
  disconnecting,
  disconnected,
}

abstract class DeviceDiscoveryService {
  Stream<List<Device>> get devices;

  Future<void> initialize() async {
    throw "Not implemented yet";
  }

  Future<void> scanForDevices({ScanFilter? filter}) async {
    throw "Not implemented yet";
  }

  void stopScan() {}

  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    return null;
  }
}
