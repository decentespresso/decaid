import 'package:reaprime/src/plugins/plugin_manifest.dart';

enum PluginStorageCommandType { read, write }

class PluginStorageCommand {
  static final id = PluginPermissions.pluginStorage.name;
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
      throw Exception("Invalid data type: $data.runtimeType");
    }
    return PluginStorageCommand(
      type: PluginStorageCommandType.values.firstWhere(
        (e) => e.name == data['type'],
      ),
      key: data['key'],
      data: data['data'],
    );
  }
}
