part of '../webserver_service.dart';

/// REST API handler for WebUI skin management
class WebUIHandler {
  final WebUIStorage _storage;
  final WebUIService _service;

  WebUIHandler({required WebUIStorage storage, required WebUIService service})
    : _storage = storage,
      _service = service;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/webui/skins', _handleListSkins);

    // Get default skin (must be before <id> to avoid route shadowing)
    app.get('/api/v1/webui/skins/default', _handleGetDefaultSkin);

    // Set default skin (must be before <id> to avoid route shadowing)
    app.put('/api/v1/webui/skins/default', _handleSetDefaultSkin);

    app.get('/api/v1/webui/skins/<id>', _handleGetSkin);

    app.post(
      '/api/v1/webui/skins/install/github-release',
      _handleInstallFromGitHubRelease,
    );

    app.post(
      '/api/v1/webui/skins/install/github-branch',
      _handleInstallFromGitHubBranch,
    );

    app.post('/api/v1/webui/skins/install/url', _handleInstallFromUrl);

    app.delete('/api/v1/webui/skins/<id>', _handleRemoveSkin);

    app.post('/api/v1/webui/skins/update', _handleUpdateSkins);

    app.get('/api/v1/webui/server/status', _handleServerStatus);
    app.post('/api/v1/webui/server/start', _handleServerStart);
    app.post('/api/v1/webui/server/stop', _handleServerStop);

    app.get('/api/v1/webui/skin-assets/<id>/<path|.*>', _handleGetSkinAssets);
  }

  /// GET /api/v1/webui/skins
  /// List all installed skins
  Future<Response> _handleListSkins(Request request) async {
    try {
      final skins = _storage.installedSkins;
      return jsonOk(skins.map((skin) => skin.toJson()).toList());
    } catch (e, st) {
      log.severe('Failed to list skins', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// GET /api/v1/webui/skins/{id}
  /// Get specific skin details
  Future<Response> _handleGetSkin(Request request, String id) async {
    try {
      final skin = _storage.getSkin(id);
      if (skin == null) {
        return jsonNotFound({'error': 'Skin not found: $id'});
      }
      return jsonOk(skin.toJson());
    } catch (e, st) {
      log.severe('Failed to get skin: $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// GET /api/v1/webui/skins/default
  /// Get the default skin
  Future<Response> _handleGetDefaultSkin(Request request) async {
    try {
      final defaultSkin = _storage.defaultSkin;
      if (defaultSkin == null) {
        return jsonNotFound({'error': 'No default skin available'});
      }
      return jsonOk(defaultSkin.toJson());
    } catch (e, st) {
      log.severe('Failed to get default skin', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// PUT /api/v1/webui/skins/default
  /// Set the default skin
  ///
  /// Body:
  /// {
  ///   "skinId": "my-skin-id"
  /// }
  Future<Response> _handleSetDefaultSkin(Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final skinId = body['skinId'] as String?;

      if (skinId == null || skinId.isEmpty) {
        return jsonBadRequest({'error': 'Missing required field: skinId'});
      }

      log.info('Setting default skin to: $skinId');
      await _storage.setDefaultSkin(skinId);

      return jsonOk({
        'success': true,
        'message': 'Default skin updated successfully',
        'skinId': skinId,
      });
    } catch (e, st) {
      log.severe('Failed to set default skin', e, st);
      if (e.toString().contains('Skin not found')) {
        return jsonNotFound({'error': e.toString()});
      }
      return jsonError({'error': e.toString()});
    }
  }

  /// POST /api/v1/webui/skins/install/github-release
  /// Install skin from GitHub release
  ///
  /// Body:
  /// {
  ///   "repo": "username/repo",
  ///   "asset": "skin.zip",       // optional
  ///   "prerelease": false         // optional
  /// }
  Future<Response> _handleInstallFromGitHubRelease(Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final repo = body['repo'] as String?;

      if (repo == null || repo.isEmpty) {
        return jsonBadRequest({'error': 'Missing required field: repo'});
      }

      final asset = body['asset'] as String?;
      final prerelease = body['prerelease'] as bool? ?? false;

      log.info('Installing skin from GitHub release: $repo');

      await _storage.installFromGitHubRelease(
        repo,
        assetName: asset,
        includePrerelease: prerelease,
      );

      return jsonOk({
        'success': true,
        'message': 'Skin installed successfully from GitHub release',
        'repo': repo,
      });
    } catch (e, st) {
      log.severe('Failed to install skin from GitHub release', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// POST /api/v1/webui/skins/install/github-branch
  /// Install skin from GitHub branch
  ///
  /// Body:
  /// {
  ///   "repo": "username/repo",
  ///   "branch": "main"            // optional, defaults to "main"
  /// }
  Future<Response> _handleInstallFromGitHubBranch(Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final repo = body['repo'] as String?;

      if (repo == null || repo.isEmpty) {
        return jsonBadRequest({'error': 'Missing required field: repo'});
      }

      final branch = body['branch'] as String? ?? 'main';

      log.info('Installing skin from GitHub branch: $repo/$branch');

      await _storage.installFromGitHub(repo, branch: branch);

      return jsonOk({
        'success': true,
        'message': 'Skin installed successfully from GitHub branch',
        'repo': repo,
        'branch': branch,
      });
    } catch (e, st) {
      log.severe('Failed to install skin from GitHub branch', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// POST /api/v1/webui/skins/install/url
  /// Install skin from direct URL
  ///
  /// Body:
  /// {
  ///   "url": "https://example.com/skin.zip"
  /// }
  Future<Response> _handleInstallFromUrl(Request request) async {
    try {
      final body =
          jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final url = body['url'] as String?;

      if (url == null || url.isEmpty) {
        return jsonBadRequest({'error': 'Missing required field: url'});
      }

      log.info('Installing skin from URL: $url');

      await _storage.installFromUrl(url);

      return jsonOk({
        'success': true,
        'message': 'Skin installed successfully from URL',
        'url': url,
      });
    } catch (e, st) {
      log.severe('Failed to install skin from URL', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  /// DELETE /api/v1/webui/skins/{id}
  /// Remove/uninstall a skin
  Future<Response> _handleRemoveSkin(Request request, String id) async {
    try {
      log.info('Removing skin: $id');

      await _storage.removeSkin(id);

      return jsonOk({
        'success': true,
        'message': 'Skin removed successfully',
        'id': id,
      });
    } catch (e, st) {
      log.severe('Failed to remove skin: $id', e, st);
      if (e.toString().contains('Cannot remove bundled skin')) {
        return jsonForbidden({'error': e.toString()});
      }
      return jsonError({'error': e.toString()});
    }
  }

  /// POST /api/v1/webui/skins/update
  /// Triggers update check for all skins from their remote sources
  Future<Response> _handleUpdateSkins(Request request) async {
    try {
      await _storage.updateAllSkins();
      return jsonOk({'message': 'Skin update check completed'});
    } catch (e) {
      return jsonError({'error': 'Failed to check for updates: $e'});
    }
  }

  /// GET /api/v1/webui/server/status
  /// Returns current WebUI server serving status
  Response _handleServerStatus(Request request) {
    return jsonOk({
      'serving': _service.isServing,
      'path': _service.isServing ? _service.serverPath() : null,
      'port': _service.isServing ? _service.port : null,
      'ip': _service.isServing ? _service.serverIP() : null,
    });
  }

  /// POST /api/v1/webui/server/start
  /// Starts serving the default skin
  Future<Response> _handleServerStart(Request request) async {
    if (_service.isServing) {
      return jsonOk({'message': 'Already serving'});
    }
    final defaultSkin = _storage.defaultSkin;
    if (defaultSkin == null) {
      return jsonBadRequest({
        'error': 'No default skin set. Set defaultSkinId in settings first.',
      });
    }
    try {
      await _service.serveFolderAtPath(defaultSkin.path);
      return jsonOk({
        'message': 'WebUI server started',
        'path': defaultSkin.path,
      });
    } catch (e) {
      return jsonError({'error': 'Failed to start: $e'});
    }
  }

  /// POST /api/v1/webui/server/stop
  /// Stops the WebUI server
  Future<Response> _handleServerStop(Request request) async {
    if (!_service.isServing) {
      return jsonOk({'message': 'Not serving'});
    }
    try {
      await _service.stopServing();
      return jsonOk({'message': 'WebUI server stopped'});
    } catch (e) {
      return jsonError({'error': 'Failed to stop: $e'});
    }
  }

  /// GET /api/v1/webui/skin-assets/{id}/{filepath}
  /// returns a file from the skin folder
  Future<Response> _handleGetSkinAssets(
    Request request,
    String id,
    String filepath,
  ) async {
    log.fine("serving $filepath for $id");

    if (!_storage.isSkinInstalled(id)) {
      return jsonNotFound({'error': 'Skin not found: $id'});
    }

    final base = p.normalize(p.absolute(_storage.getSkinPath(id)));
    final target = p.normalize(p.absolute(p.join(base, filepath)));
    if (target != base && !p.isWithin(base, target)) {
      log.warning('rejected skin-asset path traversal: $id -> $filepath');
      return jsonForbidden({'error': 'Invalid asset path'});
    }

    final resource = File(target);
    if (!await resource.exists()) {
      return jsonNotFound({'error': 'Asset not found'});
    }

    try {
      final content = await resource.readAsBytes();
      final headerBytes = content.length < 32
          ? content
          : content.sublist(0, 32);
      final type = lookupMimeType(resource.path, headerBytes: headerBytes);
      return Response.ok(
        content,
        headers: {'content-type': type ?? 'application/octet-stream'},
      );
    } catch (e, st) {
      log.warning('unable to serve requested skin asset', e, st);
      return jsonError({'exception': e.toString()});
    }
  }
}
