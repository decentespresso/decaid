import 'package:collection/collection.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/util/safe_path.dart';
import 'plugin_ble_matcher.dart';

List<String> parsePluginEnumValues(String key, dynamic schema) {
  if (schema is! Map || schema['type'] != 'enum') return const [];
  final values = schema['values'];
  if (values is! List || values.any((value) => value is! String)) {
    throw FormatException(
      'Enum setting "$key" values must be a JSON array of strings',
    );
  }
  return List<String>.unmodifiable(values.cast<String>());
}

String pluginSettingLabel(String key, dynamic schema) {
  if (schema is! Map) return key;
  final label = schema['label'];
  if (label is! String) return key;
  final trimmed = label.trim();
  return trimmed.isEmpty ? key : trimmed;
}

enum PluginDriverType { sensor, scale, grinder }

enum PluginScaleCapability {
  battery,
  flow,
  timerTelemetry,
  tare,
  timerControl,
  displayControl,
  disconnectToSleep,
}

enum PluginGrinderCapability { startStop, grindSetting, rpmControl }

List<PluginDriverDeclaration> parsePluginDrivers(dynamic json) {
  if (json == null) return const [];
  if (json is! List) {
    throw const FormatException('Plugin drivers must be an array');
  }
  if (json.length > 8) {
    throw const FormatException('A plugin may declare at most 8 drivers');
  }
  final drivers = json.map(PluginDriverDeclaration.fromJson).toList();
  if (drivers.map((driver) => driver.id).toSet().length != drivers.length) {
    throw const FormatException('Plugin driver ids must be unique');
  }
  if (drivers.where((driver) => driver.ble != null).length > 1) {
    throw const FormatException('A plugin may declare at most 1 BLE driver');
  }
  return List.unmodifiable(drivers);
}

class PluginDeviceSurface {
  final String id;
  final String role;
  final String endpoint;
  final String? label;

  const PluginDeviceSurface({
    required this.id,
    required this.role,
    required this.endpoint,
    this.label,
  });

  factory PluginDeviceSurface.fromJson(dynamic json) {
    if (json is! Map ||
        json.keys.any(
          (key) => !const {'id', 'role', 'endpoint', 'label'}.contains(key),
        ) ||
        json['id'] is! String ||
        !isSafePathComponent(json['id'] as String) ||
        json['role'] is! String ||
        !const {'settings', 'diagnostics'}.contains(json['role']) ||
        json['endpoint'] is! String ||
        !isSafePathComponent(json['endpoint'] as String) ||
        const {
          'settings',
          'source',
          'enable',
          'disable',
        }.contains(json['endpoint']) ||
        (json.containsKey('label') && json['label'] is! String)) {
      throw const FormatException('Invalid plugin device surface');
    }
    return PluginDeviceSurface(
      id: json['id'] as String,
      role: json['role'] as String,
      endpoint: json['endpoint'] as String,
      label: json['label'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'endpoint': endpoint,
    if (label != null) 'label': label,
  };
}

class PluginDriverDeclaration {
  final String id;
  final PluginDriverType type;
  final PluginBleMatcher? ble;
  final Set<PluginScaleCapability> capabilities;
  final Set<PluginGrinderCapability> grinderCapabilities;
  final Map<String, GrinderControlDescriptor> controls;
  final List<PluginDeviceSurface> surfaces;

  const PluginDriverDeclaration({
    required this.id,
    required this.type,
    this.ble,
    this.capabilities = const {},
    this.grinderCapabilities = const {},
    this.controls = const {},
    this.surfaces = const [],
  });

  factory PluginDriverDeclaration.fromJson(dynamic json) {
    if (json is! Map || json['id'] is! String || json['type'] is! String) {
      throw const FormatException('Invalid plugin driver declaration');
    }
    final id = json['id'] as String;
    final type = PluginDriverType.values.firstWhereOrNull(
      (value) => value.name == json['type'],
    );
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id) ||
        type == null) {
      throw FormatException('Invalid plugin driver declaration: $json');
    }
    final rawCapabilities = json['capabilities'] ?? const [];
    if (rawCapabilities is! List ||
        rawCapabilities.any((value) => value is! String) ||
        rawCapabilities.toSet().length != rawCapabilities.length ||
        (type == PluginDriverType.sensor && rawCapabilities.isNotEmpty)) {
      throw const FormatException('Invalid driver capabilities');
    }
    final capabilities = type == PluginDriverType.scale
        ? rawCapabilities.map((value) {
            final capability = PluginScaleCapability.values.firstWhereOrNull(
              (capability) => capability.name == value,
            );
            if (capability == null) {
              throw const FormatException('Unknown Scale capability');
            }
            return capability;
          }).toSet()
        : const <PluginScaleCapability>{};
    final grinderCapabilities = type == PluginDriverType.grinder
        ? rawCapabilities.map((value) {
            final capability = PluginGrinderCapability.values.firstWhereOrNull(
              (capability) => capability.name == value,
            );
            if (capability == null) {
              throw const FormatException('Unknown Grinder capability');
            }
            return capability;
          }).toSet()
        : const <PluginGrinderCapability>{};
    if (capabilities.contains(PluginScaleCapability.displayControl) &&
        capabilities.contains(PluginScaleCapability.disconnectToSleep)) {
      throw const FormatException('Scale display sleep capabilities conflict');
    }
    PluginBleMatcher? ble;
    if (json.containsKey('ble')) {
      final declaration = json['ble'];
      if (declaration is! Map ||
          declaration.length != 1 ||
          !declaration.containsKey('match')) {
        throw const FormatException('Invalid BLE declaration');
      }
      ble = PluginBleMatcher.fromJson(declaration['match']);
    }
    final rawControls = json['controls'];
    if (json.containsKey('controls') &&
        (type != PluginDriverType.grinder ||
            rawControls is! Map ||
            rawControls.keys.any(
              (key) =>
                  key is! String ||
                  !grinderCapabilities.any(
                    (capability) => capability.name == key,
                  ),
            ))) {
      throw const FormatException('Invalid Grinder controls');
    }
    final controls = <String, GrinderControlDescriptor>{};
    if (rawControls is Map) {
      for (final entry in rawControls.entries) {
        controls[entry.key as String] = GrinderControlDescriptor.fromJson(
          entry.key as String,
          entry.value,
        );
      }
    }
    final rawSurfaces = json['surfaces'];
    if (json.containsKey('surfaces') &&
        (rawSurfaces is! List || rawSurfaces.length > 8)) {
      throw const FormatException('Invalid plugin device surfaces');
    }
    final surfaces = rawSurfaces == null
        ? <PluginDeviceSurface>[]
        : (rawSurfaces as List).map(PluginDeviceSurface.fromJson).toList();
    if (surfaces.map((surface) => surface.id).toSet().length !=
            surfaces.length ||
        surfaces.where((surface) => surface.role == 'settings').length > 1) {
      throw const FormatException('Invalid plugin device surfaces');
    }
    return PluginDriverDeclaration(
      id: id,
      type: type,
      ble: ble,
      capabilities: Set.unmodifiable(capabilities),
      grinderCapabilities: Set.unmodifiable(grinderCapabilities),
      controls: Map.unmodifiable(controls),
      surfaces: List.unmodifiable(surfaces),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    if (capabilities.isNotEmpty || grinderCapabilities.isNotEmpty)
      'capabilities':
          (type == PluginDriverType.grinder
                  ? grinderCapabilities
                  : capabilities)
              .map((value) => value.name)
              .toList(),
    if (ble != null) 'ble': {'match': ble!.toJson()},
    if (controls.isNotEmpty)
      'controls': controls.map((key, value) => MapEntry(key, value.toJson())),
    if (surfaces.isNotEmpty)
      'surfaces': surfaces.map((surface) => surface.toJson()).toList(),
  };
}

class PluginManifest {
  final String id;
  final String name;
  final String author;
  final String description;
  final String version;
  final int apiVersion;
  final Set<PluginPermissions> permissions;
  final List<PluginDriverDeclaration> drivers;
  final Map<String, dynamic> settings;
  final PluginApi? api;

  PluginManifest({
    required this.id,
    required this.name,
    required this.author,
    required this.description,
    required this.version,
    required this.apiVersion,
    required this.permissions,
    this.drivers = const [],
    required this.settings,
    required this.api,
  });

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    final settings = Map<String, dynamic>.from(json['settings'] ?? {});
    for (final entry in settings.entries) {
      parsePluginEnumValues(entry.key, entry.value);
    }
    final permissions = PluginPermissionsFromJson.fromJson(json['permissions']);
    final api = PluginApi.fromJsonList(json['api']);
    final drivers = parsePluginDrivers(json['drivers']);
    for (final surface in drivers.expand((driver) => driver.surfaces)) {
      final targets = api.endpoints.where(
        (endpoint) => endpoint.id == surface.endpoint,
      );
      if (!permissions.contains(PluginPermissions.api) ||
          targets.length != 1 ||
          targets.single.type != ApiEndpointType.http) {
        throw const FormatException(
          'Plugin surface requires a declared HTTP endpoint and api permission',
        );
      }
    }
    return PluginManifest(
      id: json['id'],
      name: json['name'],
      author: json['author'],
      description: json['description'],
      version: json['version'],
      apiVersion: json['apiVersion'],
      permissions: permissions,
      drivers: drivers,
      settings: settings,
      api: api,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'author': author,
      'description': description,
      'version': version,
      'apiVersion': apiVersion,
      'permissions': permissions.map((e) => e.wireName).toList(),
      'drivers': drivers.map((driver) => driver.toJson()).toList(),
      'settings': settings,
      'api': api?.toJson(),
    };
  }
}

enum PluginPermissions {
  log('log'),
  api('api'),
  emit('emit'),
  pluginStorage('pluginStorage'),
  eventsMachine('events.machine'),
  eventsShots('events.shots'),
  eventsWorkflow('events.workflow'),
  proxyDecentApi('proxy.decent_api'),
  proxyDecentApiWrite('proxy.decent_api.write'),
  networkWebsocket('network.websocket'),
  networkTcp('network.tcp'),
  networkTls('network.tls'),
  transportBle('transport.ble');

  final String wireName;

  const PluginPermissions(this.wireName);

  static PluginPermissions? fromString(String value) {
    return PluginPermissions.values.firstWhereOrNull(
      (e) => e.wireName == value,
    );
  }
}

extension PluginPermissionsFromJson on PluginPermissions {
  static Set<PluginPermissions> fromJson(dynamic json) {
    if (json is! List<dynamic>) {
      return <PluginPermissions>{};
    }
    return json.map((value) {
      if (value is! String) {
        throw FormatException('Invalid plugin permission: $value');
      }
      final permission = PluginPermissions.fromString(value);
      if (permission == null) {
        throw FormatException('Unknown plugin permission: $value');
      }
      return permission;
    }).toSet();
  }
}

final class PluginApi {
  final List<ApiEndpoint> endpoints;
  PluginApi({required this.endpoints});
  factory PluginApi.fromJsonList(List<dynamic> json) {
    return PluginApi(
      endpoints: json.map((e) => ApiEndpoint.fromJson(e)).toList(),
    );
  }

  List<dynamic> toJson() {
    return endpoints.map((e) {
      return e.toJson();
    }).toList();
  }
}

final class ApiEndpoint {
  final String id;
  final ApiEndpointType type;
  final Map<String, dynamic> data;

  ApiEndpoint({required this.id, required this.type, required this.data});

  factory ApiEndpoint.fromJson(Map<String, dynamic> json) {
    return ApiEndpoint(
      id: json['id'],
      type: ApiEndpointType.values.firstWhere((e) => e.name == json['type']),
      data: json['data'],
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'type': type.name, 'data': data};
  }
}

enum ApiEndpointType { websocket, http }
