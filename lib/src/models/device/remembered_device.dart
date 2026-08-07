import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

class RememberedDevice {
  final String id;
  final String name;
  final DeviceType type;

  final DeviceImplementation? implementation;

  final TransportType? transportType;

  const RememberedDevice({
    required this.id,
    required this.name,
    required this.type,
    this.implementation,
    this.transportType,
  }) : assert(id.length > 0, 'a remembered device must have a non-empty id');

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    if (implementation != null) 'implementation': implementation!.name,
    if (transportType != null) 'transportType': transportType!.name,
  };

  bool sameMetadata(RememberedDevice other) =>
      other.name == name &&
      other.type == type &&
      other.implementation == implementation &&
      other.transportType == transportType;

  static RememberedDevice? fromDevice(Device device) {
    if (device is SimulatedDevice) return null;
    if (device.deviceId.isEmpty) return null;
    return RememberedDevice(
      id: device.deviceId,
      name: device.name,
      type: device.type,
      implementation: device.implementation,
      transportType: device.transportType,
    );
  }

  static RememberedDevice? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final typeName = json['type'];
    if (id is! String || id.isEmpty || name is! String || typeName is! String) {
      return null;
    }
    final type = DeviceType.values.firstWhereOrNull((t) => t.name == typeName);
    if (type == null) return null;

    DeviceImplementation? impl;
    final implName = json['implementation'];
    if (implName is String) {
      impl = DeviceImplementation.values.firstWhereOrNull(
        (i) => i.name == implName,
      );
    }

    TransportType? tt;
    final ttName = json['transportType'];
    if (ttName is String) {
      tt = TransportType.values.firstWhereOrNull((t) => t.name == ttName);
    }

    return RememberedDevice(
      id: id,
      name: name,
      type: type,
      implementation: impl,
      transportType: tt,
    );
  }

  RememberedDevice migrate(
    DeviceImplementation? Function(String name) nameToImplementation,
  ) {
    return RememberedDevice(
      id: id,
      name: name,
      type: type,
      implementation: implementation ?? nameToImplementation(name),
      transportType: transportType ?? _inferTransportType(id),
    );
  }

  static TransportType _inferTransportType(String deviceId) {
    if (deviceId.startsWith('wifi:')) return TransportType.wifi;
    if (deviceId.startsWith('serial-') || deviceId.startsWith('usb-')) {
      return TransportType.serial;
    }
    if (deviceId.contains('/dev/')) return TransportType.serial;
    if (RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(deviceId)) {
      return TransportType.ble;
    }
    if (RegExp(
      r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
    ).hasMatch(deviceId)) {
      return TransportType.ble;
    }
    return TransportType.ble;
  }

  static String encodeList(Iterable<RememberedDevice> devices) =>
      jsonEncode(devices.map((d) => d.toJson()).toList());

  static List<RememberedDevice> decodeList(String json) {
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((m) => RememberedDevice.fromJson(Map<String, dynamic>.from(m)))
        .whereType<RememberedDevice>()
        .toList();
  }

  static int storedCount(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is List ? decoded.length : 0;
    } catch (_) {
      return 0;
    }
  }

  @override
  bool operator ==(Object other) => other is RememberedDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'RememberedDevice($id, $name, ${type.name}, impl=${implementation?.name}, transport=${transportType?.name})';
}
