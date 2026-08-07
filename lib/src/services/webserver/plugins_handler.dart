part of '../webserver_service.dart';

final class PluginsHandler {
  final PluginManager pluginManager;
  final PluginLoaderService pluginService;

  final Logger _log = Logger("PluginsHandler");

  final Random _random = Random();

  PluginsHandler({required this.pluginManager, required this.pluginService});

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/plugins', (Request req) async {
      final list = <Map<String, dynamic>>[];
      for (final manifest in pluginService.availablePlugins) {
        final json = manifest.toJson();
        json['loaded'] = pluginService.isPluginLoaded(manifest.id);
        json['autoLoad'] = await pluginService.shouldAutoLoad(manifest.id);
        list.add(json);
      }
      return jsonOk(list);
    });

    app.post('/api/v1/plugins/install', (Request request) async {
      try {
        final payload = await request.readAsString();
        final json = jsonDecode(payload) as Map<String, dynamic>;
        final url = json['url'] as String?;
        if (url == null || url.isEmpty) {
          return jsonBadRequest({'error': 'url is required'});
        }
        return jsonNotImplemented({
          'error': 'Plugin install from URL not yet implemented',
        });
      } catch (e) {
        return jsonError({'error': 'Failed to install plugin: $e'});
      }
    });

    app.get('/api/v1/plugins/<id>/settings', _handlePluginSettingsGet);
    app.post('/api/v1/plugins/<id>/settings', _handlePluginSettingsPost);

    app.post('/api/v1/plugins/<id>/enable', (Request request, String id) async {
      try {
        if (pluginService.getPluginManifest(id) == null) {
          return jsonNotFound({'error': 'Plugin not found: $id'});
        }
        await pluginService.setPluginAutoLoad(id, true);
        if (!pluginService.isPluginLoaded(id)) {
          await pluginService.loadPlugin(id);
        }
        return jsonOk({'message': 'Plugin enabled', 'id': id});
      } catch (e) {
        return jsonError({'error': 'Failed to enable plugin: $e'});
      }
    });

    app.post('/api/v1/plugins/<id>/disable', (
      Request request,
      String id,
    ) async {
      try {
        if (pluginService.getPluginManifest(id) == null) {
          return jsonNotFound({'error': 'Plugin not found: $id'});
        }
        if (pluginService.isPluginLoaded(id)) {
          await pluginService.unloadPlugin(id);
        }
        await pluginService.setPluginAutoLoad(id, false);
        return jsonOk({'message': 'Plugin disabled', 'id': id});
      } catch (e) {
        return jsonError({'error': 'Failed to disable plugin: $e'});
      }
    });

    app.delete('/api/v1/plugins/<id>', (Request request, String id) async {
      try {
        if (pluginService.getPluginManifest(id) == null) {
          return jsonNotFound({'error': 'Plugin not found: $id'});
        }
        await pluginService.removePlugin(id);
        return jsonOk({'message': 'Plugin removed', 'id': id});
      } catch (e) {
        return jsonError({'error': 'Failed to remove plugin: $e'});
      }
    });

    app.get('/ws/v1/plugins/<id>/<endpoint>', _handlePluginSocketEndpoint);
    app.all('/api/v1/plugins/<id>/<endpoint>', _handlePluginApiEndpoint);
  }

  Future<Response> _handlePluginSocketEndpoint(Request req) async {
    _log.info("handling $req");
    final id = req.params['id'];
    final endpoint = req.params['endpoint'];
    final manifest = pluginManager.loadedPlugins
        .firstWhereOrNull((e) => e.pluginId == id)
        ?.manifest;
    if (manifest == null) {
      return jsonNotFound({'error': 'plugin with $id not loaded'});
    }
    final apiEndpoint = manifest.api?.endpoints.firstWhereOrNull(
      (e) => e.id == endpoint,
    );
    if (apiEndpoint == null) {
      return jsonNotFound({'error': 'endpoint $endpoint not available'});
    }
    if (apiEndpoint.type != ApiEndpointType.websocket) {
      return jsonBadRequest({
        'error': 'endpoint $endpoint is not a websocket type',
      });
    }

    return sws.webSocketHandler((WebSocketChannel socket, String? protocol) {
      StreamSubscription<Map<String, dynamic>>? sub;
      sub = pluginManager.emitStream
          .where((e) {
            return e['pluginId'] == id && e['event'] == endpoint;
          })
          .listen(
            (data) {
              socket.sink.add(jsonEncode(data['payload']));
            },
            onDone: () {
              socket.sink.close();
              sub?.cancel();
            },
            onError: (e) {
              _log.warning("plugin $id listen errored out:", e);
              sub?.cancel();
            },
          );
      socket.stream.listen(
        (msg) {},
        onDone: () {
          sub?.cancel();
        },
        onError: (e, _) {
          sub?.cancel();
          _log.warning("socket connection error: ", e);
        },
      );
    })(req);
  }

  Future<Response> _handlePluginApiEndpoint(Request req) async {
    _log.info("handling ${req.toString()}");

    final id = req.params['id'];
    final endpoint = req.params['endpoint'];

    if (id == null || endpoint == null) {
      return jsonBadRequest({'error': 'id and endpoint required'});
    }

    final manifest = pluginManager.loadedPlugins
        .firstWhereOrNull((e) => e.pluginId == id)
        ?.manifest;

    if (manifest == null) {
      return jsonNotFound({'error': 'plugin with $id not loaded'});
    }
    if (!manifest.permissions.contains(PluginPermissions.api)) {
      _log.warning('Plugin $id denied permission api');
      return jsonForbidden({
        'error':
            'PluginPermissionError: Plugin $id requires manifest permission api',
      });
    }

    final apiEndpoint = manifest.api?.endpoints.firstWhereOrNull(
      (e) => e.id == endpoint,
    );

    if (apiEndpoint == null) {
      return jsonNotFound({'error': 'endpoint $endpoint not available'});
    }

    if (apiEndpoint.type != ApiEndpointType.http) {
      return jsonBadRequest({'error': 'endpoint $endpoint is not a http type'});
    }

    final method = req.method;
    final headers = <String, String>{};
    req.headers.forEach((name, values) {
      headers[name] = values;
    });

    final body = await req.readAsString();

    final requestId =
        '${id}_${endpoint}_${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(100000)}';

    try {
      final requestData = {
        'requestId': requestId,
        'endpoint': endpoint,
        'method': method,
        'headers': headers,
        'body': body.isNotEmpty ? jsonDecode(body) : null,
        'query': req.url.queryParameters,
      };

      final responseFuture = pluginManager.registerPendingHttp(id, requestId);

      pluginManager.dispatchEvent(id, 'httpRequest', requestData);

      final response = await responseFuture;

      final status = response['status'] as int? ?? 200;
      final responseHeaders =
          (response['headers'] as Map<String, dynamic>? ?? {}).map(
            (k, v) => MapEntry(k, v.toString()),
          );
      final responseBody = response['body'];

      return Response(status, body: responseBody, headers: responseHeaders);
    } on PluginHttpError catch (e) {
      _log.warning("Plugin $id HTTP request failed", e);
      return jsonError({'error': e.message});
    } catch (e) {
      _log.warning("Error handling HTTP request for plugin $id", e);
      return jsonError({'error': 'Error processing request: ${e.toString()}'});
    }
  }

  Future<Response> _extractPluginId(
    Request req,
    Future<Response> Function(Request, String) call,
  ) async {
    final id = req.params['id'];
    if (id == null) {
      return jsonBadRequest({'error': 'plugin id is required'});
    }
    return call(req, id);
  }

  Future<Response> _handlePluginSettingsGet(Request req) async {
    return _extractPluginId(req, (r, id) async {
      final settings = await pluginService.pluginSettings(id);
      return jsonOk(settings);
    });
  }

  Future<Response> _handlePluginSettingsPost(Request req) async {
    return _extractPluginId(req, (req, id) async {
      final body = await req.readAsString();
      final json = await jsonDecode(body);
      try {
        await pluginService.savePluginSettings(id, json);
      } on PluginSettingsValidationException catch (e) {
        return jsonBadRequest({'error': e.message});
      }
      await pluginService.reloadPlugin(id);
      return jsonOk(await pluginService.pluginSettings(id));
    });
  }
}
