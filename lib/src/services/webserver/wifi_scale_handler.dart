import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:reaprime/src/services/wifi/wifi_scale_discovery_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

class WifiScaleHandler {
  final WifiScaleDiscoveryService _service;
  final Logger _log = Logger('WifiScaleHandler');

  WifiScaleHandler({required WifiScaleDiscoveryService service})
    : _service = service;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/devices/wifi', _list);
    app.post('/api/v1/devices/wifi', _add);
    app.delete('/api/v1/devices/wifi', _remove);
  }

  Response _list(Request req) {
    return jsonOk({'endpoints': _service.manualEndpoints});
  }

  Future<Response> _add(Request req) async {
    final String? host = await _extractHost(req);
    if (host == null || host.isEmpty) {
      return jsonBadRequest({'error': 'missing "host"'});
    }
    try {
      await _service.addManualEndpoint(host);
      _log.info('added manual WiFi endpoint: $host');
      return jsonOk({'endpoints': _service.manualEndpoints});
    } catch (e, st) {
      _log.warning('failed to add manual WiFi endpoint $host', e, st);
      return jsonBadRequest({'error': e.toString()});
    }
  }

  Future<Response> _remove(Request req) async {
    final String? host = await _extractHost(req);
    if (host == null || host.isEmpty) {
      return jsonBadRequest({'error': 'missing "host"'});
    }
    try {
      await _service.removeManualEndpoint(host);
      _log.info('removed manual WiFi endpoint: $host');
      return jsonOk({'endpoints': _service.manualEndpoints});
    } catch (e, st) {
      _log.warning('failed to remove manual WiFi endpoint $host', e, st);
      return jsonBadRequest({'error': e.toString()});
    }
  }

  Future<String?> _extractHost(Request req) async {
    String body;
    try {
      body = await req.readAsString();
    } catch (e, st) {
      _log.warning('failed to read request body', e, st);
      return req.requestedUri.queryParameters['host']?.trim();
    }
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic> && decoded['host'] is String) {
          return (decoded['host'] as String).trim();
        }
      } on FormatException {
        // Not valid JSON — fall through to the query parameter.
      }
    }
    return req.requestedUri.queryParameters['host']?.trim();
  }
}
