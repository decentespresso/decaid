import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

/// Lightweight, persistable record of a device the user has connected to.
/// Metadata only — it is NOT a live [Device] (no transport, no
/// connectionState). The API surfaces a remembered device that isn't currently
/// present as `available: false`.
class RememberedDevice {
  final String id;
  final String name;
  final DeviceType type;

  /// The concrete [DeviceImplementation] for this device. Null on old records
  /// written before this field existed — the controller infers it on load.
  final DeviceImplementation? implementation;

  /// The [TransportType] this device communicates over. Null on old records
  /// — the controller infers it on load.
  final TransportType? transportType;

  const RememberedDevice({
    required this.id,
    required this.name,
    required this.type,
    this.implementation,
    this.transportType,
  }) : assert(id.length > 0, 'a remembered device must have a non-empty id');

  // NOTE: `type.name`, `implementation.name`, and `transportType.name` are
  // PERSISTED WIRE CONTRACTS. The enum identifier is what gets written to and
  // read from storage (see [fromJson]), so renaming an enum value would
  // silently orphan every stored record of that type.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    if (implementation != null) 'implementation': implementation!.name,
    if (transportType != null) 'transportType': transportType!.name,
  };

  /// Whether [other] carries the same display metadata (name + type). Identity
  /// (`==`) is id-only, so the registry uses this to detect a metadata change on
  /// reconnect without widening equality.
  bool sameMetadata(RememberedDevice other) =>
      other.name == name &&
      other.type == type &&
      other.implementation == implementation &&
      other.transportType == transportType;

  /// Build a record from a live [Device], or null if the device is simulated
  /// (a [SimulatedDevice] is governed by the simulate setting, not real
  /// discovery, so it is never remembered). This is the point that keeps mocks
  /// out of the remembered registry.
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

  /// Parse one record. Returns null for malformed input, an empty id, or an
  /// unknown type — so [decodeList] never throws and never builds an invalid
  /// record.
  ///
  /// Old records missing `implementation` and `transportType` load with nulls.
  /// The controller infers them on load via [migrate].
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

  /// Return a copy with [implementation] and [transportType] filled in,
  /// inferring from [name] and [id] when they are null. Used by the controller
  /// to migrate old records on first load after update.
  ///
  /// [nameToImplementation] is injected so tests can supply a custom matcher.
  /// Production passes [DeviceMatcher.implementationForName].
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

  /// Heuristic transport-type inference from device-id format, used only for
  /// old records that predate the `transportType` field.
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

  /// Encode a list to the JSON string persisted in settings.
  static String encodeList(Iterable<RememberedDevice> devices) =>
      jsonEncode(devices.map((d) => d.toJson()).toList());

  /// Decode the persisted JSON string. Malformed entries are skipped; a fully
  /// malformed string yields an empty list (never throws).
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

  /// Number of records present in the stored string before validity filtering.
  /// Lets a caller detect dropped/unreadable entries by comparing against
  /// `decodeList(...).length`. Returns 0 for a non-list / malformed string.
  static int storedCount(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is List ? decoded.length : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Identity is the device id (one remembered entry per device).
  @override
  bool operator ==(Object other) => other is RememberedDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'RememberedDevice($id, $name, ${type.name}, impl=${implementation?.name}, transport=${transportType?.name})';
}
