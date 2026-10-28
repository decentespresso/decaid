import 'package:path/path.dart' as p;
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_runtime.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

List<String> collectInstalledComponents({
  required WebUIService webUIService,
  required WebUIStorage webUIStorage,
  required PluginLoaderService pluginService,
}) {
  return installedComponentLines(
    isServing: webUIService.isServing,
    servedPath: webUIService.serverPath(),
    installedSkins: webUIStorage.installedSkins,
    loadedPlugins: pluginService.loadedPlugins,
  );
}

List<String> installedComponentLines({
  required bool isServing,
  required String servedPath,
  required List<WebUISkin> installedSkins,
  required Iterable<PluginRuntime> loadedPlugins,
}) {
  return [
    _skinLine(isServing, servedPath, installedSkins),
    _pluginLine(loadedPlugins),
  ];
}

String _skinLine(
  bool isServing,
  String servedPath,
  List<WebUISkin> installedSkins,
) {
  final served = servedPath.trim();
  if (!isServing || served.isEmpty) return 'Skin: none served';
  final canonical = _canonical(served);
  for (final skin in installedSkins) {
    if (_canonical(skin.path) == canonical) {
      return 'Skin: ${skin.id} ${skin.version ?? 'unknown'}';
    }
  }
  return 'Skin: unregistered (${p.basename(p.normalize(served))}) unknown';
}

String _pluginLine(Iterable<PluginRuntime> loadedPlugins) {
  final plugins = [
    for (final plugin in loadedPlugins)
      '${plugin.manifest.id} ${plugin.manifest.version}',
  ];
  if (plugins.isEmpty) return 'Loaded plugins: none';
  return 'Loaded plugins: ${plugins.join(', ')}';
}

String _canonical(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '';
  return p.canonicalize(trimmed);
}
