import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

enum DeviceType { machine, scale, sensor }

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

class DeviceInformation {
  final String? firmwareVersion;
  final int? batteryLevel;
  final DevicePowerSource? powerSource;
  final DevicePowerSourceProvenance? powerSourceProvenance;

  const DeviceInformation({
    this.firmwareVersion,
    this.batteryLevel,
    this.powerSource,
    this.powerSourceProvenance,
  });

  bool get isEmpty =>
      firmwareVersion == null &&
      batteryLevel == null &&
      powerSource == null &&
      powerSourceProvenance == null;

  Map<String, dynamic> toJson() => {
    if (firmwareVersion != null) 'firmwareVersion': firmwareVersion,
    if (batteryLevel != null) 'batteryLevel': batteryLevel,
    if (powerSource != null) 'powerSource': powerSource!.name,
    if (powerSourceProvenance != null)
      'powerSourceProvenance': powerSourceProvenance!.name,
  };
}

enum DevicePowerSource { battery, usb, external, unknown }

enum DevicePowerSourceProvenance { deviceReported, manualOverride }

abstract interface class DeviceInformationCapable {
  DeviceInformation? get currentDeviceInformation;
  Stream<DeviceInformation?> get deviceInformation;
}

abstract interface class UsbPowerConfigurable {
  bool get usbPowered;
  Future<void> setUsbPowered(bool value);
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
