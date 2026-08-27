part of '../webserver_service.dart';

final class PluginsHandler {
  final PluginManager pluginManager;
  final PluginLoaderService pluginService;
  final PluginSourceService pluginSourceService;

  final Logger _log = Logger("PluginsHandler");

  final Random _random = Random();

  PluginsHandler({
    required this.pluginManager,
    required PluginLoaderService pluginService,
    PluginSourceService? pluginSourceService,
  }) : pluginService = pluginService,
       pluginSourceService =
           pluginSourceService ?? PluginSourceService(pluginService);

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/plugins', (Request req) async {
      final list = <Map<String, dynamic>>[];
      for (final manifest in pluginService.availablePlugins) {
        final json = manifest.toJson();
        json['loaded'] = pluginService.isPluginLoaded(manifest.id);
        json['autoLoad'] = await pluginService.shouldAutoLoad(manifest.id);
        final source = pluginSourceService.sourceFor(manifest.id);
        json['source'] = source == null ? null : _sourceJson(source);
        json['pendingUpdate'] = source?.pendingUpdate?.toJson();
        list.add(json);
      }
      return jsonOk(list);
    });

    app.post('/api/v1/plugins/install', (Request request) async {
      return jsonNotImplemented({
        'error':
            'Plugin install from an arbitrary URL is not supported. Use '
            '/api/v1/plugins/install/github-release or '
            '/api/v1/plugins/install/github-branch',
      });
    });

    app.post(
      '/api/v1/plugins/install/github-release',
      _handleInstallFromGitHubRelease,
    );

    app.post(
      '/api/v1/plugins/install/github-branch',
      _handleInstallFromGitHubBranch,
    );

    app.post('/api/v1/plugins/update', (Request request) async {
      try {
        await pluginSourceService.updateAllPlugins();
        return jsonOk({'message': 'Plugin update check complete'});
      } catch (e) {
        _log.warning('Plugin update check failed', e);
        return jsonError({'error': 'Failed to update plugins: $e'});
      }
    });

    app.get('/api/v1/plugins/<id>/settings', _handlePluginSettingsGet);
    app.post('/api/v1/plugins/<id>/settings', _handlePluginSettingsPost);

    app.put('/api/v1/plugins/<id>/source', _handlePluginSourceWrite);

    app.post('/api/v1/plugins/<id>/enable', (Request request, String id) async {
      try {
        if (pluginService.getPluginManifest(id) == null) {
          return jsonNotFound({'error': 'Plugin not found: $id'});
        }
        await pluginService.enablePlugin(id);
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
        await pluginService.disablePlugin(id);
        return jsonOk({'message': 'Plugin disabled', 'id': id});
      } catch (e) {
        return jsonError({'error': 'Failed to disable plugin: $e'});
      }
    });

    app.post('/api/v1/plugins/<id>/update/approve', (
      Request request,
      String id,
    ) async {
      if (pluginService.getPluginManifest(id) == null) {
        return jsonNotFound({'error': 'Plugin not found: $id'});
      }
      try {
        final manifest = await pluginSourceService.approvePendingUpdate(id);
        return jsonOk({
          'message': 'Plugin updated',
          'id': id,
          'version': manifest.version,
          'loaded': pluginService.isPluginLoaded(id),
        });
      } on PluginApprovalRequiredException catch (e) {
        return jsonConflict({'error': e.message});
      } on FormatException catch (e) {
        return jsonBadRequest({'error': e.message});
      } catch (e) {
        _log.warning('Failed to approve update of plugin $id', e);
        return jsonError({'error': 'Failed to approve update: $e'});
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

  Map<String, dynamic> _sourceJson(PluginSource source) {
    final json = source.toJson();
    json.remove('pendingUpdate');
    return json;
  }

  Future<Response> _handleInstallFromGitHubRelease(Request request) async {
    final Map<String, dynamic> json;
    try {
      json =
          jsonDecode(
                await readBoundedRequestBodyString(
                  request,
                  maxBytes: smallRequestBodyBytes,
                  timeout: smallRequestBodyTimeout,
                ),
              )
              as Map<String, dynamic>;
    } on RequestBodyReadException {
      rethrow;
    } catch (e) {
      return jsonBadRequest({'error': 'Invalid JSON body: $e'});
    }

    final repo = json['repo'];
    if (repo is! String || repo.isEmpty) {
      return jsonBadRequest({'error': 'repo is required (owner/repo)'});
    }
    final assetName = json['assetName'];
    if (assetName != null && assetName is! String) {
      return jsonBadRequest({'error': 'assetName must be a string'});
    }
    final includePrerelease = json['includePrerelease'];
    if (includePrerelease != null && includePrerelease is! bool) {
      return jsonBadRequest({'error': 'includePrerelease must be a boolean'});
    }

    return _install(
      () => pluginSourceService.installFromGitHubRelease(
        repo,
        assetName: assetName as String?,
        includePrerelease: (includePrerelease as bool?) ?? false,
      ),
    );
  }

  Future<Response> _handleInstallFromGitHubBranch(Request request) async {
    final Map<String, dynamic> json;
    try {
      json =
          jsonDecode(
                await readBoundedRequestBodyString(
                  request,
                  maxBytes: smallRequestBodyBytes,
                  timeout: smallRequestBodyTimeout,
                ),
              )
              as Map<String, dynamic>;
    } on RequestBodyReadException {
      rethrow;
    } catch (e) {
      return jsonBadRequest({'error': 'Invalid JSON body: $e'});
    }

    final repo = json['repo'];
    if (repo is! String || repo.isEmpty) {
      return jsonBadRequest({'error': 'repo is required (owner/repo)'});
    }
    final branch = json['branch'];
    if (branch != null && branch is! String) {
      return jsonBadRequest({'error': 'branch must be a string'});
    }

    return _install(
      () => pluginSourceService.installFromGitHubBranch(
        repo,
        branch: (branch as String?) ?? 'main',
      ),
    );
  }

  Future<Response> _install(Future<PluginManifest> Function() install) async {
    try {
      final manifest = await install();
      return jsonOk({
        'message': 'Plugin installed',
        'id': manifest.id,
        'version': manifest.version,
        'loaded': pluginService.isPluginLoaded(manifest.id),
      });
    } on PluginDowngradeException catch (e) {
      return jsonConflict({'error': e.message});
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.message});
    } catch (e) {
      _log.warning('Plugin installation failed', e);
      return jsonError({'error': 'Failed to install plugin: $e'});
    }
  }

  Future<Response> _handlePluginSourceWrite(Request request, String id) async {
    final Map<String, dynamic> json;
    try {
      json =
          jsonDecode(
                await readBoundedRequestBodyString(
                  request,
                  maxBytes: largeRequestBodyBytes,
                  timeout: largeRequestBodyTimeout,
                ),
              )
              as Map<String, dynamic>;
    } on RequestBodyReadException {
      rethrow;
    } catch (e) {
      return jsonBadRequest({'error': 'Invalid JSON body: $e'});
    }

    final manifestJson = json['manifest'];
    final pluginJs = json['plugin'];
    if (manifestJson is! Map<String, dynamic>) {
      return jsonBadRequest({'error': 'manifest object is required'});
    }
    if (pluginJs is! String || pluginJs.isEmpty) {
      return jsonBadRequest({'error': 'plugin source is required'});
    }

    try {
      final manifest = await pluginService.updatePluginSource(
        id,
        manifestJson: manifestJson,
        pluginJs: pluginJs,
      );
      return jsonOk({
        'message': 'Plugin source updated',
        'id': id,
        'version': manifest.version,
        'loaded': pluginService.isPluginLoaded(id),
      });
    } on PluginDowngradeException catch (e) {
      return jsonConflict({'error': e.message});
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.message});
    } catch (e) {
      _log.warning('Failed to update source of plugin $id', e);
      return jsonError({
        'error': 'Failed to update plugin source: $e',
        'id': id,
        'loaded': pluginService.isPluginLoaded(id),
      });
    }
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

    return admittedWebSocketHandler((
      WebSocketChannel socket,
      String? protocol,
    ) {
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

    final body = await readBoundedRequestBodyString(
      req,
      maxBytes: largeRequestBodyBytes,
    );

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
      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
        timeout: largeRequestBodyTimeout,
      );
      final json = await jsonDecode(body);
      try {
        await pluginService.savePluginSettings(id, json);
      } on PluginSettingsValidationException catch (e) {
        return jsonBadRequest({'error': e.message});
      }
      return jsonOk(await pluginService.pluginSettings(id));
    });
  }
}
