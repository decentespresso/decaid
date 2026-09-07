import 'package:reaprime/src/models/device/ble_service_identifier.dart';

enum PluginBleMatch { match, noMatch, indeterminate }

String normalizePluginBleUuid(String value) {
  final lower = value.toLowerCase();
  if (RegExp(r'^[0-9a-f]{8}$').hasMatch(lower)) {
    return '$lower-0000-1000-8000-00805f9b34fb';
  }
  try {
    return BleServiceIdentifier.parse(lower).long;
  } on ArgumentError {
    throw const FormatException('Invalid BLE UUID');
  }
}

class PluginBleMatcher {
  final String? nameMode;
  final String? nameValue;
  final List<String>? serviceUuids;

  const PluginBleMatcher._(this.nameMode, this.nameValue, this.serviceUuids);

  factory PluginBleMatcher.fromJson(dynamic json) {
    if (json is! Map ||
        json.isEmpty ||
        json.keys.any((key) => key != 'name' && key != 'serviceUuids')) {
      throw const FormatException('Invalid BLE matcher');
    }
    String? nameMode;
    String? nameValue;
    if (json.containsKey('name')) {
      final name = json['name'];
      if (name is! Map ||
          name.length != 1 ||
          !const ['exact', 'prefix', 'contains'].contains(name.keys.single) ||
          name.values.single is! String ||
          (name.values.single as String).isEmpty ||
          (name.values.single as String).length > 248) {
        throw const FormatException('Invalid BLE name predicate');
      }
      nameMode = name.keys.single as String;
      nameValue = name.values.single as String;
    }
    List<String>? services;
    if (json.containsKey('serviceUuids')) {
      final values = json['serviceUuids'];
      if (values is! List ||
          values.isEmpty ||
          values.length > 64 ||
          values.any((value) => value is! String)) {
        throw const FormatException('Invalid BLE service UUID list');
      }
      services = List.unmodifiable(
        values.cast<String>().map(normalizePluginBleUuid),
      );
    }
    return PluginBleMatcher._(nameMode, nameValue, services);
  }

  PluginBleMatch evaluate({
    String? name,
    Iterable<String>? serviceUuids,
    bool servicesComplete = true,
  }) {
    var unresolved = false;
    if (nameMode != null) {
      if (name == null) {
        unresolved = true;
      } else {
        final lower = name.toLowerCase();
        final expected = nameValue!.toLowerCase();
        final matches = switch (nameMode) {
          'exact' => lower == expected,
          'prefix' => lower.startsWith(expected),
          _ => lower.contains(expected),
        };
        if (!matches) return PluginBleMatch.noMatch;
      }
    }
    final requiredServices = this.serviceUuids;
    if (requiredServices != null) {
      if (serviceUuids == null) {
        unresolved = true;
      } else {
        final matches = serviceUuids
            .map(normalizePluginBleUuid)
            .any(requiredServices.contains);
        if (!matches) {
          if (servicesComplete) return PluginBleMatch.noMatch;
          unresolved = true;
        }
      }
    }
    return unresolved ? PluginBleMatch.indeterminate : PluginBleMatch.match;
  }

  Map<String, dynamic> toJson() => {
    if (nameMode != null) 'name': {nameMode!: nameValue},
    if (serviceUuids != null) 'serviceUuids': serviceUuids,
  };
}
