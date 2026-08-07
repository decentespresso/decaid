import 'package:logging/logging.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';

class PluginDecentProxyBridge {
  final DecentProxyService? decentProxyService;
  final Logger _log;

  PluginDecentProxyBridge({required this.decentProxyService, Logger? log})
    : _log = log ?? Logger('PluginDecentProxyBridge');

  /// Exact paths a plugin holding `proxy.decent_api.write` may POST to. Writes
  /// are least-privilege: a specific method + a specific path, never the whole
  /// `support/api/` namespace. Add entries here as new write endpoints appear.
  static const Set<String> _writeAllowedPaths = {'support/api/shot_upload'};

  static String _canonicalPath(String path) =>
      path.trim().replaceAll(RegExp(r'^/+'), '');

  Future<Map<String, dynamic>> proxyForPlugin({
    required String pluginId,
    required PluginManifest? manifest,
    required String? path,
    String method = 'GET',
    Map<String, String>? query,
    String? body,
    String? contentType,
  }) async {
    if (manifest == null) {
      throw StateError('Plugin is not loaded: $pluginId');
    }
    if (decentProxyService == null) {
      throw StateError('Decent account proxy is not available');
    }
    if (path == null || path.trim().isEmpty) {
      throw ArgumentError('Decent proxy path is required');
    }

    final normalizedMethod = method.toUpperCase();
    final callerId = 'plugin:$pluginId';
    final canonicalPath = _canonicalPath(path);
    final DecentProxyResponse response;
    switch (normalizedMethod) {
      case 'GET':
        if (!manifest.permissions.contains(PluginPermissions.proxyDecentApi)) {
          _log.warning('Plugin $pluginId GET without proxy.decent_api');
          throw StateError('Plugin permission required: proxy.decent_api');
        }
        response = await decentProxyService!.proxyGet(
          callerId: callerId,
          path: path,
          query: query,
        );
      case 'POST':
        if (!manifest.permissions.contains(
          PluginPermissions.proxyDecentApiWrite,
        )) {
          _log.warning('Plugin $pluginId POST without proxy.decent_api.write');
          throw StateError(
            'Plugin permission required: proxy.decent_api.write',
          );
        }
        if (!_writeAllowedPaths.contains(canonicalPath)) {
          _log.warning(
            'Plugin $pluginId POST to disallowed path $canonicalPath',
          );
          throw StateError('Decent proxy write not allowed for path: $path');
        }
        response = await decentProxyService!.proxyPost(
          callerId: callerId,
          path: path,
          query: query,
          body: body,
          contentType: contentType,
        );
      default:
        throw UnsupportedError(
          'Decent proxy supports GET and POST for plugins',
        );
    }
    return {
      'status': response.statusCode,
      'headers': response.headers,
      'body': response.body,
    };
  }
}
