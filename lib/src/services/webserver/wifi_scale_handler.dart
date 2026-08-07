import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:reaprime/src/services/wifi/wifi_scale_discovery_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

/// REST surface for manually-entered WiFi scale endpoints.
///
/// Discovered (DNS-SD) WiFi scales flow through the normal device streams and
/// need no API. But a manual IP/hostname has to be driven from the skin, which
/// can't call the Dart [WifiScaleDiscoveryService] directly — so these routes
/// expose `addManualEndpoint`/`removeManualEndpoint`/list over HTTP.
///
/// A manually-added endpoint surfaces in the device list as a
/// "Half Decent Scale (WiFi)" entry and connects/validates through the existing
/// recognition gate: a bad IP shows up as a scale that never reaches
/// `connected`.
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

  /// `{ "endpoints": ["hds.local", "192.168.1.42"] }`
  Response _list(Request req) {
    return jsonOk({'endpoints': _service.manualEndpoints});
  }

  /// `POST` with `{ "host": "<ip-or-hostname>" }` → adds the endpoint and
  /// returns the updated list. Idempotent.
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

  /// `DELETE` with `{ "host": "..." }` (body or `?host=` query) → removes the
  /// endpoint (tearing down its scale) and returns the updated list.
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

  /// Extract `host` from a JSON body, falling back to a `?host=` query param
  /// (so `DELETE` works for clients that can't send a body).
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
