import 'dart:convert';

import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:shelf/shelf.dart' as shelf;

class PluginLocalApiBridge {
  static const _pathPrefix = '/api/v1/';
  static const _methods = {'GET', 'POST', 'PUT', 'DELETE'};

  static final _managementRoutes = ExtensionManagementRouteMatcher([
    ...extensionManagementRoutes,
    ...extensionManagementReadRoutes,
  ]);
  static final _settingsRoute = ExtensionManagementRouteMatcher(const [
    extensionManagementSettingsRoute,
  ]);

  final int maxResponseBytes;

  shelf.Handler? handler;

  PluginLocalApiBridge({required this.maxResponseBytes});

  Future<Map<String, dynamic>> request({
    required ExtensionManagementGrant grant,
    required Object? path,
    Object? method,
    Object? body,
    Object? contentType,
  }) async {
    final handler = this.handler;
    if (handler == null) {
      throw StateError('The local API is not available');
    }
    final target = shelf.Request(_method(method), _localUri(path));
    final changesSettings = await _settingsRoute.matches(target);
    if (!changesSettings && !await _managementRoutes.matches(target)) {
      throw ArgumentError(
        'localApi reaches only the plugin and skin management routes, not '
        '${target.method} /${target.url.path}',
      );
    }
    final requestBody = changesSettings ? _extensionSettings(body) : body;
    final request = shelf.Request(
      target.method,
      target.requestedUri,
      headers: {
        if (requestBody != null)
          'content-type': contentType is String
              ? contentType
              : 'application/json',
      },
      body: requestBody == null
          ? null
          : requestBody is String
          ? requestBody
          : jsonEncode(requestBody),
      context: {extensionManagementGrantContextKey: grant},
    );

    final response = await handler(request);
    final bytes = await response.read().fold<List<int>>([], (acc, chunk) {
      if (acc.length + chunk.length > maxResponseBytes) {
        throw StateError('response exceeds $maxResponseBytes bytes');
      }
      return acc..addAll(chunk);
    });
    return {
      'status': response.statusCode,
      'headers': response.headers,
      'body': utf8.decode(bytes, allowMalformed: true),
    };
  }

  static String _extensionSettings(Object? body) {
    Object? settings = body;
    if (body is String) {
      try {
        settings = jsonDecode(body);
      } on FormatException {
        settings = null;
      }
    }
    if (settings is! Map ||
        settings.isEmpty ||
        !settings.keys.every(extensionManagementSettingsKeys.contains)) {
      throw ArgumentError(
        'localApi changes only these settings: '
        '${extensionManagementSettingsKeys.join(', ')}',
      );
    }
    return jsonEncode(settings);
  }

  static String _method(Object? method) {
    final normalized = method is String ? method.toUpperCase() : null;
    if (method == null) return 'GET';
    if (normalized == null || !_methods.contains(normalized)) {
      throw ArgumentError('localApi does not support method $method');
    }
    return normalized;
  }

  static Uri _localUri(Object? path) {
    final uri = path is String ? Uri.tryParse(path) : null;
    if (uri == null ||
        uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasFragment ||
        !uri.path.startsWith(_pathPrefix)) {
      throw ArgumentError('localApi path must start with $_pathPrefix');
    }
    return Uri(
      scheme: 'http',
      host: 'localhost',
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
    );
  }
}
