part of '../webserver_service.dart';

class ProfileHandler {
  final ProfileController _controller;

  ProfileHandler({required ProfileController controller})
    : _controller = controller;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/profiles', _handleGetAll);

    app.get('/api/v1/profiles/defaults', _handleListDefaults);
    app.get('/api/v1/profiles/export', _handleExport);

    app.get('/api/v1/profiles/<id>', _handleGetById);

    app.post('/api/v1/profiles', _handleCreate);

    app.put('/api/v1/profiles/<id>', _handleUpdate);

    app.delete('/api/v1/profiles/<id>', _handleDelete);

    app.put('/api/v1/profiles/<id>/visibility', _handleSetVisibility);

    app.get('/api/v1/profiles/<id>/lineage', _handleGetLineage);

    app.post('/api/v1/profiles/import', _handleImport);

    app.post('/api/v1/profiles/restore/<filename>', _handleRestoreDefault);

    app.delete('/api/v1/profiles/<id>/purge', _handlePurge);
  }

  Future<Response> _handleGetAll(Request request) async {
    try {
      final params = request.url.queryParameters;
      final visibilityParam = params['visibility'];
      final includeHidden = params['includeHidden'] == 'true';
      final parentId = params['parentId'];

      Visibility? visibility;
      if (visibilityParam != null) {
        try {
          visibility = VisibilityExtension.fromString(visibilityParam);
        } catch (e) {
          return jsonBadRequest({
            'error': 'Invalid visibility value',
            'message': 'Valid values: visible, hidden, deleted',
          });
        }
      }

      List<ProfileRecord> profiles;

      if (parentId != null) {
        final allProfiles = await _controller.getAll(includeHidden: true);
        profiles = allProfiles.where((p) => p.parentId == parentId).toList();
      } else {
        profiles = await _controller.getAll(
          visibility: visibility,
          includeHidden: includeHidden,
        );
      }

      return jsonOkConditional(
        request,
        profiles.map((p) => p.toJson()).toList(),
      );
    } catch (e, st) {
      log.severe('Error in _handleGetAll', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleListDefaults(Request request) async {
    try {
      final defaults = await _controller.listDefaults();
      return jsonOk(defaults);
    } catch (e, st) {
      log.severe('Error in _handleListDefaults', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleGetById(Request request, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final profile = await _controller.get(id);

      if (profile == null) {
        return jsonNotFound({'error': 'Profile not found', 'id': id});
      }

      return jsonOk(profile.toJson());
    } catch (e, st) {
      log.severe('Error in _handleGetById', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleCreate(Request request) async {
    try {
      final body = await readBoundedRequestBodyString(
        request,
        maxBytes: largeRequestBodyBytes,
        timeout: largeRequestBodyTimeout,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;

      if (!json.containsKey('profile')) {
        return jsonBadRequest({
          'error': 'Missing required field',
          'message': 'Request must contain "profile" field',
        });
      }

      final profile = Profile.fromJson(json['profile'] as Map<String, dynamic>);
      final parentId = json['parentId'] as String?;
      final metadata = json['metadata'] as Map<String, dynamic>?;

      final record = await _controller.create(
        profile: profile,
        parentId: parentId,
        metadata: metadata,
      );

      return jsonCreated(record.toJson());
    } on RequestBodyReadException {
      rethrow;
    } on ArgumentError catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } on FormatException catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } catch (e, st) {
      log.severe('Error in _handleCreate', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleUpdate(Request request, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final body = await readBoundedRequestBodyString(
        request,
        maxBytes: largeRequestBodyBytes,
        timeout: largeRequestBodyTimeout,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;

      Profile? profile;
      if (json.containsKey('profile')) {
        final profileJson = json['profile'];
        if (profileJson == null) {
          throw const FormatException('Field "profile" cannot be null');
        }
        profile = Profile.fromJson(profileJson as Map<String, dynamic>);
      }

      final metadata = json['metadata'] as Map<String, dynamic>?;

      final record = await _controller.update(
        id,
        profile: profile,
        metadata: metadata,
        metadataPresent: json.containsKey('metadata'),
      );

      return jsonOk(record.toJson());
    } on RequestBodyReadException {
      rethrow;
    } on ArgumentError catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } on FormatException catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } on TypeError catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } catch (e, st) {
      log.severe('Error in _handleUpdate', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleDelete(Request request, String id) async {
    id = Uri.decodeComponent(id);
    try {
      await _controller.delete(id);

      return jsonOk({'success': true, 'message': 'Profile deleted', 'id': id});
    } on ArgumentError catch (e) {
      return jsonNotFound({'error': 'Not found', 'message': '$e'});
    } catch (e, st) {
      log.severe('Error in _handleDelete', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleSetVisibility(Request request, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final body = await readBoundedRequestBodyString(
        request,
        maxBytes: smallRequestBodyBytes,
        timeout: smallRequestBodyTimeout,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;

      if (!json.containsKey('visibility')) {
        return jsonBadRequest({
          'error': 'Missing required field',
          'message': 'Request must contain "visibility" field',
        });
      }

      final visibilityStr = json['visibility'] as String;
      final visibility = VisibilityExtension.fromString(visibilityStr);

      final record = await _controller.setVisibility(id, visibility);

      return jsonOk(record.toJson());
    } on RequestBodyReadException {
      rethrow;
    } on ArgumentError catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } catch (e, st) {
      log.severe('Error in _handleSetVisibility', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleGetLineage(Request request, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final lineage = await _controller.getLineage(id);

      if (lineage.isEmpty) {
        return jsonNotFound({'error': 'Profile not found', 'id': id});
      }

      return jsonOk(lineage.map((p) => p.toJson()).toList());
    } catch (e, st) {
      log.severe('Error in _handleGetLineage', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleImport(Request request) async {
    try {
      final body = await readBoundedRequestBodyString(
        request,
        maxBytes: largeRequestBodyBytes,
        timeout: largeRequestBodyTimeout,
      );
      final json = jsonDecode(body);

      if (json is! List) {
        return jsonBadRequest({
          'error': 'Invalid request',
          'message': 'Request body must be an array of profile records',
        });
      }

      final profilesJson = json.cast<Map<String, dynamic>>();
      final result = await _controller.importProfiles(profilesJson);

      return jsonOk(result);
    } on RequestBodyReadException {
      rethrow;
    } catch (e, st) {
      log.severe('Error in _handleImport', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleExport(Request request) async {
    try {
      final params = request.url.queryParameters;
      final includeHidden = params['includeHidden'] == 'true';
      final includeDeleted = params['includeDeleted'] == 'true';

      final profiles = await _controller.exportProfiles(
        includeHidden: includeHidden,
        includeDeleted: includeDeleted,
      );

      return Response.ok(
        jsonEncode(profiles),
        headers: {
          'Content-Type': 'application/json',
          'Content-Disposition': 'attachment; filename="profiles_export.json"',
        },
      );
    } catch (e, st) {
      log.severe('Error in _handleExport', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handleRestoreDefault(
    Request request,
    String filename,
  ) async {
    try {
      final record = await _controller.restoreDefault(filename);

      return jsonOk(record.toJson());
    } on ArgumentError catch (e) {
      return jsonNotFound({'error': 'Not found', 'message': '$e'});
    } catch (e, st) {
      log.severe('Error in _handleRestoreDefault', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }

  Future<Response> _handlePurge(Request request, String id) async {
    id = Uri.decodeComponent(id);
    try {
      await _controller.purge(id);

      return jsonOk({
        'success': true,
        'message': 'Profile permanently deleted',
        'id': id,
      });
    } on ArgumentError catch (e) {
      return jsonBadRequest({'error': 'Invalid request', 'message': '$e'});
    } catch (e, st) {
      log.severe('Error in _handlePurge', e, st);
      return jsonError({'error': 'Internal server error', 'message': '$e'});
    }
  }
}
