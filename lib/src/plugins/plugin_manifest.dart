import 'package:collection/collection.dart';

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

class PluginManifest {
  final String id;
  final String name;
  final String author;
  final String description;
  final String version;
  final int apiVersion;
  final Set<PluginPermissions> permissions;
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
    required this.settings,
    required this.api,
  });

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    final settings = Map<String, dynamic>.from(json['settings'] ?? {});
    for (final entry in settings.entries) {
      parsePluginEnumValues(entry.key, entry.value);
    }
    return PluginManifest(
      id: json['id'],
      name: json['name'],
      author: json['author'],
      description: json['description'],
      version: json['version'],
      apiVersion: json['apiVersion'],
      permissions: PluginPermissionsFromJson.fromJson(json['permissions']),
      settings: settings,
      api: PluginApi.fromJsonList(json['api']),
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
  proxyDecentApi('proxy.decent_api'),
  proxyDecentApiWrite('proxy.decent_api.write'),
  networkWebsocket('network.websocket'),
  networkTcp('network.tcp'),
  networkTls('network.tls');

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
