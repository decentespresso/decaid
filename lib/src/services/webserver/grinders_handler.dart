import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/grinder.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/webserver/json_patch.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

class GrindersHandler {
  final GrinderStorageService _storage;
  final Logger _log = Logger('GrindersHandler');

  GrindersHandler({required GrinderStorageService storage})
    : _storage = storage;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/grinders', _getGrinders);
    app.get('/api/v1/grinders/<id>', _getGrinder);
    app.post('/api/v1/grinders', _createGrinder);
    app.put('/api/v1/grinders/<id>', _updateGrinder);
    app.delete('/api/v1/grinders/<id>', _deleteGrinder);
  }

  Future<Response> _getGrinders(Request req) async {
    try {
      final includeArchived =
          req.url.queryParameters['includeArchived'] == 'true';
      final grinders = await _storage.getAllGrinders(
        includeArchived: includeArchived,
      );
      return jsonOkConditional(req, grinders.map((g) => g.toJson()).toList());
    } catch (e, st) {
      _log.severe('Error getting grinders', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getGrinder(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final grinder = await _storage.getGrinderById(id);
      if (grinder == null) {
        return jsonNotFound({'error': 'Grinder not found'});
      }
      return jsonOk(grinder.toJson());
    } catch (e, st) {
      _log.severe('Error getting grinder $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _createGrinder(Request req) async {
    try {
      final body = await req.body.asString;
      final json = jsonDecode(body) as Map<String, dynamic>;
      final grinder = Grinder.create(
        model: json['model'] as String,
        burrs: json['burrs'] as String?,
        burrSize: (json['burrSize'] as num?)?.toDouble(),
        burrType: json['burrType'] as String?,
        notes: json['notes'] as String?,
        settingType: json['settingType'] != null
            ? GrinderSettingType.fromString(json['settingType'] as String)
            : GrinderSettingType.numeric,
        settingValues: (json['settingValues'] as List?)?.cast<String>(),
        settingSmallStep: (json['settingSmallStep'] as num?)?.toDouble(),
        settingBigStep: (json['settingBigStep'] as num?)?.toDouble(),
        rpmSmallStep: (json['rpmSmallStep'] as num?)?.toDouble(),
        rpmBigStep: (json['rpmBigStep'] as num?)?.toDouble(),
        extras: json['extras'] as Map<String, dynamic>?,
      );
      await _storage.insertGrinder(grinder);
      return jsonCreated(grinder.toJson());
    } catch (e, st) {
      _log.severe('Error creating grinder', e, st);
      return jsonBadRequest({'error': e.toString()});
    }
  }

  Future<Response> _updateGrinder(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final existing = await _storage.getGrinderById(id);
      if (existing == null) {
        return jsonNotFound({'error': 'Grinder not found'});
      }

      final body = await req.body.asString;
      final json = jsonDecode(body) as Map<String, dynamic>;

      rejectExplicitNulls(json, const ['model', 'archived', 'settingType']);
      final updated = Grinder.fromJson({
        ...existing.toJson(),
        ...json,
        'id': existing.id,
        'createdAt': existing.createdAt.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      });

      await _storage.updateGrinder(updated);
      return jsonOk(updated.toJson());
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.toString()});
    } on TypeError catch (e) {
      return jsonBadRequest({'error': e.toString()});
    } catch (e, st) {
      _log.severe('Error updating grinder $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _deleteGrinder(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      await _storage.deleteGrinder(id);
      return jsonOk({'success': true, 'id': id});
    } catch (e, st) {
      _log.severe('Error deleting grinder $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }
}
