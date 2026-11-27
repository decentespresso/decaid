import 'package:reaprime/src/plugins/plugin_manifest.dart';

enum PluginStorageCommandType { read, write }

class PluginStorageCommand {
  static final id = PluginPermissions.pluginStorage.name;
  static const version = 2;
  static const maxRequestId = 9007199254740991;

  final PluginStorageCommandType type;
  final String key;
  final dynamic data;

  PluginStorageCommand({
    required this.type,
    required this.key,
    required this.data,
  });

  factory PluginStorageCommand.fromPlugin(dynamic data) {
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid storage command');
    }
    final type = PluginStorageCommandType.values
        .where((e) => e.name == data['type'])
        .firstOrNull;
    final key = data['key'];
    if (type == null ||
        key is! String ||
        (type == PluginStorageCommandType.write && data['data'] == null)) {
      throw const FormatException('Invalid storage command');
    }
    return PluginStorageCommand(type: type, key: key, data: data['data']);
  }

  static bool isVersioned(dynamic data) =>
      data is Map && data['version'] is int;

  static int? requestIdFrom(Object? value) {
    final id = switch (value) {
      int v => v,
      double v when v.isFinite && v == v.truncateToDouble() => v.toInt(),
      _ => null,
    };
    return id != null && id >= 0 && id <= maxRequestId ? id : null;
  }
}
