import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/equipment.dart';
import 'package:reaprime/src/services/storage/equipment_storage_service.dart';
import 'package:reaprime/src/services/webserver/bounded_request_body.dart';
import 'package:reaprime/src/services/webserver/json_patch.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

class EquipmentHandler {
  final EquipmentStorageService _storage;
  final Logger _log = Logger('EquipmentHandler');

  EquipmentHandler({required EquipmentStorageService storage})
    : _storage = storage;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/equipment', _getEquipment);
    app.get('/api/v1/equipment/<id>', _getEquipmentById);
    app.post('/api/v1/equipment', _createEquipment);
    app.put('/api/v1/equipment/<id>', _updateEquipment);
    app.delete('/api/v1/equipment/<id>', _deleteEquipment);
  }

  Future<Response> _getEquipment(Request req) async {
    try {
      final includeArchived =
          req.url.queryParameters['includeArchived'] == 'true';
      final typeParam = req.url.queryParameters['type'];
      final type = typeParam != null
          ? EquipmentType.fromString(typeParam)
          : null;
      final equipment = await _storage.getAllEquipment(
        includeArchived: includeArchived,
        type: type,
      );
      return jsonOkConditional(
        req,
        equipment.map((e) => e.toJson()).toList(),
      );
    } catch (e, st) {
      _log.severe('Error getting equipment', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getEquipmentById(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final equipment = await _storage.getEquipmentById(id);
      if (equipment == null) {
        return jsonNotFound({'error': 'Equipment not found'});
      }
      return jsonOk(equipment.toJson());
    } catch (e, st) {
      _log.severe('Error getting equipment $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _createEquipment(Request req) async {
    try {
      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;
      final equipment = Equipment.create(
        type: json['type'] != null
            ? EquipmentType.fromString(json['type'] as String)
            : EquipmentType.other,
        name: json['name'] as String,
        style: json['style'] as String?,
        diameterMm: (json['diameterMm'] as num?)?.toDouble(),
        notes: json['notes'] as String?,
        tools: (json['tools'] as List?)?.cast<String>(),
        extras: json['extras'] as Map<String, dynamic>?,
      );
      await _storage.insertEquipment(equipment);
      return jsonCreated(equipment.toJson());
    } on RequestBodyReadException {
      rethrow;
    } catch (e, st) {
      _log.severe('Error creating equipment', e, st);
      return jsonBadRequest({'error': e.toString()});
    }
  }

  Future<Response> _updateEquipment(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final existing = await _storage.getEquipmentById(id);
      if (existing == null) {
        return jsonNotFound({'error': 'Equipment not found'});
      }

      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;

      rejectExplicitNulls(json, const ['type', 'name', 'archived']);
      validatePatchFieldTypes(
        json,
        numberFields: const ['diameterMm'],
        stringListFields: const ['tools'],
      );
      final updated = Equipment.fromJson({
        ...existing.toJson(),
        ...json,
        'id': existing.id,
        'createdAt': existing.createdAt.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      });

      await _storage.updateEquipment(updated);
      return jsonOk(updated.toJson());
    } on RequestBodyReadException {
      rethrow;
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.toString()});
    } on TypeError catch (e) {
      return jsonBadRequest({'error': e.toString()});
    } catch (e, st) {
      _log.severe('Error updating equipment $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _deleteEquipment(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      await _storage.deleteEquipment(id);
      return jsonOk({'success': true, 'id': id});
    } catch (e, st) {
      _log.severe('Error deleting equipment $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }
}
