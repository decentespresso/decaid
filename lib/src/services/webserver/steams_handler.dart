import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

class SteamsHandler {
  final PersistenceController _controller;
  final Logger _log = Logger('SteamsHandler');

  SteamsHandler({required PersistenceController controller})
    : _controller = controller;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/steams', _getSteams);
    app.get('/api/v1/steams/ids', _getIds);
    app.get('/api/v1/steams/latest', _getLatest);
    app.get('/api/v1/steams/<id>', _getSteam);
    app.put('/api/v1/steams/<id>', _updateSteam);
    app.delete('/api/v1/steams/<id>', _deleteSteam);
  }

  Future<Response> _getSteams(Request req) async {
    try {
      final records = await _controller.storageService.getAllSteams();
      final items = records.map((r) => r.toJsonWithoutMeasurements()).toList();
      return jsonOk(items);
    } catch (e, st) {
      _log.severe('Error getting steams', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getIds(Request req) async {
    try {
      final ids = await _controller.storageService.getSteamIds();
      return jsonOk(ids);
    } catch (e, st) {
      _log.severe('Error getting steam IDs', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getLatest(Request req) async {
    try {
      final record = await _controller.storageService.getLatestSteamMeta();
      return jsonOk(record?.toJsonWithoutMeasurements());
    } catch (e, st) {
      _log.severe('Error getting latest steam', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getSteam(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final record = await _controller.storageService.getSteam(id);
      if (record == null) {
        return jsonNotFound({'error': 'Steam record not found'});
      }
      return jsonOk(record.toJson());
    } catch (e, st) {
      _log.severe('Error getting steam $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _updateSteam(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final body = await req.body.asString;
      final json = jsonDecode(body) as Map<String, dynamic>;

      if (json['id'] != null && json['id'] != id) {
        return jsonBadRequest({
          'error': 'ID in path does not match ID in body',
        });
      }

      final existing = await _controller.storageService.getSteam(id);
      if (existing == null) {
        return jsonNotFound({'error': 'Steam record not found'});
      }

      ShotAnnotations? annotations = existing.annotations;
      if (json['annotations'] != null) {
        annotations = ShotAnnotations.fromJson(
          json['annotations'] as Map<String, dynamic>,
        );
      }

      final updated = existing.copyWith(annotations: annotations);
      await _controller.updateSteam(updated);
      return jsonOk(updated.toJson());
    } catch (e, st) {
      _log.severe('Error updating steam $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _deleteSteam(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      await _controller.deleteSteam(id);
      return jsonOk({'success': true, 'id': id});
    } catch (e, st) {
      _log.severe('Error deleting steam $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }
}
