import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/webserver/bounded_request_body.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

class ShotsHandler {
  final PersistenceController _controller;
  final BeanStorageService? _beanStorage;
  final PluginManager? _pluginManager;

  final Logger _log = Logger("ShotsHandler");

  ShotsHandler({
    required PersistenceController controller,
    BeanStorageService? beanStorage,
    PluginManager? pluginManager,
  }) : _controller = controller,
       _beanStorage = beanStorage,
       _pluginManager = pluginManager;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/shots', _getShots);
    app.get('/api/v1/shots/ids', _getIds);
    app.get('/api/v1/shots/latest', _getLatestShot);
    app.get('/api/v1/shots/<id>', _getShot);
    app.put('/api/v1/shots/<id>', _updateShot);
    app.delete('/api/v1/shots/<id>', _deleteShot);
  }

  Future<Response> _getShots(Request req) async {
    _log.fine('params: ${req.url.queryParametersAll}');

    final params = req.url.queryParameters;

    final limit = int.tryParse(params['limit'] ?? '') ?? 20;
    final offset = int.tryParse(params['offset'] ?? '') ?? 0;

    final grinderId = params['grinderId'];
    final grinderModel = params['grinderModel'];
    final beanId = params['beanId'];
    final beanBatchId = params['beanBatchId'];
    final coffeeName = params['coffeeName'];
    final coffeeRoaster = params['coffeeRoaster'];
    final profileTitle = params['profileTitle'];
    final search = params['search'];

    final rawIds = req.url.queryParametersAll['ids'];
    final ids = rawIds
        ?.expand((id) => id.split(','))
        .where((id) => id.isNotEmpty)
        .toList();
    final hasFilters =
        grinderId != null ||
        grinderModel != null ||
        beanId != null ||
        beanBatchId != null ||
        coffeeName != null ||
        coffeeRoaster != null ||
        profileTitle != null ||
        search != null;

    if (ids != null && ids.isNotEmpty && !hasFilters) {
      final shots = <ShotRecord>[];
      for (final id in ids) {
        final shot = await _controller.storageService.getShot(id);
        if (shot != null) shots.add(shot);
      }

      final order = params['order'] ?? 'desc';
      if (order != 'asc' && order != 'desc') {
        return jsonBadRequest({
          "error": "Invalid order value. Supported: asc, desc",
        });
      }
      shots.sort(
        (a, b) => order == 'asc'
            ? a.timestamp.compareTo(b.timestamp)
            : b.timestamp.compareTo(a.timestamp),
      );

      return jsonOk(shots.map((e) => e.toJson()).toList());
    }

    try {
      final order = params['order'];
      final ascending = order == 'asc';
      final beanBatchIds = await _beanBatchIdsForBeanFilter(beanId);
      if (beanId != null && beanBatchIds == null) {
        return jsonBadRequest({
          "error": "beanId filtering requires bean storage",
        });
      }
      if (beanBatchIds != null && beanBatchIds.isEmpty) {
        return jsonOkConditional(req, {
          'items': <Map<String, dynamic>>[],
          'total': 0,
          'limit': limit,
          'offset': offset,
        });
      }

      final shots = await _controller.storageService.getShotsPaginated(
        limit: limit.clamp(1, 100),
        offset: offset.clamp(0, 1 << 30),
        grinderId: grinderId,
        grinderModel: grinderModel,
        beanBatchId: beanBatchId,
        beanBatchIds: beanBatchIds,
        coffeeName: coffeeName,
        coffeeRoaster: coffeeRoaster,
        profileTitle: profileTitle,
        search: search,
        ascending: ascending,
      );

      final total = await _controller.storageService.countShots(
        grinderId: grinderId,
        grinderModel: grinderModel,
        beanBatchId: beanBatchId,
        beanBatchIds: beanBatchIds,
        coffeeName: coffeeName,
        coffeeRoaster: coffeeRoaster,
        profileTitle: profileTitle,
        search: search,
      );

      final items = shots.map((s) => s.toJsonWithoutMeasurements()).toList();

      return jsonOkConditional(req, {
        'items': items,
        'total': total,
        'limit': limit,
        'offset': offset,
      });
    } catch (e, st) {
      _log.severe('Error getting paginated shots', e, st);
      return jsonError({"error": e.toString()});
    }
  }

  Future<List<String>?> _beanBatchIdsForBeanFilter(String? beanId) async {
    if (beanId == null) return null;
    final storage = _beanStorage;
    if (storage == null) return null;
    final batches = await storage.getBatchesForBean(
      Uri.decodeComponent(beanId),
      includeArchived: true,
    );
    return batches.map((batch) => batch.id).toList();
  }

  Future<Response> _getIds(Request req) async {
    try {
      final ids = await _controller.storageService.getShotIds();
      return jsonOk(ids);
    } catch (e, st) {
      _log.severe('Error getting shot IDs', e, st);
      return jsonError({"error": e.toString()});
    }
  }

  Future<Response> _getLatestShot(Request req) async {
    try {
      final shot = await _controller.storageService.getLatestShotMeta();
      return jsonOk(shot?.toJsonWithoutMeasurements());
    } catch (e, st) {
      _log.severe('Error getting latest shot', e, st);
      return jsonError({"error": e.toString()});
    }
  }

  Future<Response> _getShot(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final shot = await _controller.storageService.getShot(id);
      if (shot == null) {
        return jsonNotFound({"error": "Shot not found"});
      }
      return jsonOk(shot.toJson());
    } catch (e, st) {
      _log.severe("Error getting shot $id", e, st);
      return jsonError({"error": e.toString()});
    }
  }

  Future<Response> _updateShot(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
        timeout: largeRequestBodyTimeout,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;

      if (json['id'] != null && json['id'] != id) {
        return jsonBadRequest({
          "error": "ID in path does not match ID in body",
        });
      }

      if (json.containsKey('measurements')) {
        return jsonBadRequest({
          "error": "measurements is not editable via this endpoint",
        });
      }

      if (json.containsKey('createdAt') || json.containsKey('updatedAt')) {
        return jsonBadRequest({
          "error":
              "createdAt and updatedAt are system-managed and cannot be "
              "modified via this endpoint",
        });
      }

      final existingShot = await _controller.storageService.getShot(id);
      if (existingShot == null) {
        return jsonNotFound({"error": "Shot not found"});
      }

      final merged = _deepMerge(
        existingShot.toJson(),
        _normalizeLegacyAnnotationPatch(json),
      );
      _synchronizeLegacyAnnotationAliases(merged);
      merged['id'] = id;

      final contentChanged = !ShotRecord.fromJson(
        merged,
      ).sameContent(existingShot);
      merged['updatedAt'] =
          (contentChanged
                  ? DateTime.now().toUtc()
                  : existingShot.updatedAt ??
                        existingShot.createdAt ??
                        existingShot.timestamp)
              .toIso8601String();

      final updatedShot = ShotRecord.fromJson(merged);
      await _controller.updateShot(updatedShot);
      _log.info("Broadcasting shotUpdated for ${updatedShot.id}");
      _pluginManager?.broadcastEvent('shotUpdated', {
        'id': updatedShot.id,
        'shot': updatedShot.toJsonWithoutMeasurements(),
        'patch': json,
      });

      return jsonOk(updatedShot.toJson());
    } on RequestBodyReadException {
      rethrow;
    } catch (e, st) {
      _log.severe("Error updating shot $id", e, st);
      return jsonError({"error": e.toString()});
    }
  }

  Future<Response> _deleteShot(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      await _controller.deleteShot(id);
      return jsonOk({"success": true, "id": id});
    } catch (e, st) {
      _log.severe("Error deleting shot $id", e, st);
      if (e.toString().contains("not found")) {
        return jsonNotFound({"error": "Shot not found"});
      }
      return jsonError({"error": e.toString()});
    }
  }

  Map<String, dynamic> _normalizeLegacyAnnotationPatch(
    Map<String, dynamic> patch,
  ) {
    final normalized = Map<String, dynamic>.from(patch);

    if (patch.containsKey('annotations')) {
      final annotations = patch['annotations'];
      if (annotations is Map<String, dynamic>) {
        final normalizedAnnotations = Map<String, dynamic>.from(annotations);
        if (!annotations.containsKey('espressoNotes') &&
            patch.containsKey('shotNotes')) {
          normalizedAnnotations['espressoNotes'] = patch['shotNotes'];
        }
        if (!annotations.containsKey('extras') &&
            patch.containsKey('metadata')) {
          normalizedAnnotations['extras'] = patch['metadata'];
        }
        normalized['annotations'] = normalizedAnnotations;
      }
    } else if (patch.containsKey('shotNotes') ||
        patch.containsKey('metadata')) {
      normalized['annotations'] = <String, dynamic>{
        if (patch.containsKey('shotNotes')) 'espressoNotes': patch['shotNotes'],
        if (patch.containsKey('metadata')) 'extras': patch['metadata'],
      };
    }

    normalized.remove('shotNotes');
    normalized.remove('metadata');
    return normalized;
  }

  void _synchronizeLegacyAnnotationAliases(Map<String, dynamic> json) {
    if (!json.containsKey('annotations')) return;

    final annotations = json['annotations'];
    if (annotations is Map<String, dynamic>) {
      final espressoNotes = annotations['espressoNotes'];
      final extras = annotations['extras'];
      if (espressoNotes != null) {
        json['shotNotes'] = espressoNotes;
      } else {
        json.remove('shotNotes');
      }
      if (extras != null) {
        json['metadata'] = extras;
      } else {
        json.remove('metadata');
      }
    } else {
      json.remove('shotNotes');
      json.remove('metadata');
    }
  }

  Map<String, dynamic> _deepMerge(
    Map<String, dynamic> base,
    Map<String, dynamic> overrides,
  ) {
    final result = Map<String, dynamic>.from(base);
    for (final key in overrides.keys) {
      final baseValue = result[key];
      final overrideValue = overrides[key];
      if (baseValue is Map<String, dynamic> &&
          overrideValue is Map<String, dynamic>) {
        result[key] = _deepMerge(baseValue, overrideValue);
      } else {
        result[key] = overrideValue;
      }
    }
    return result;
  }
}
