import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/bean.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/webserver/bounded_request_body.dart';
import 'package:reaprime/src/services/webserver/json_patch.dart';
import 'package:reaprime/src/services/webserver/json_response.dart';
import 'package:shelf_plus/shelf_plus.dart';

class BeansHandler {
  final BeanStorageService _storage;
  final Logger _log = Logger('BeansHandler');

  BeansHandler({required BeanStorageService storage}) : _storage = storage;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/beans', _getBeans);
    app.get('/api/v1/beans/<id>', _getBean);
    app.post('/api/v1/beans', _createBean);
    app.put('/api/v1/beans/<id>', _updateBean);
    app.delete('/api/v1/beans/<id>', _deleteBean);

    app.get('/api/v1/beans/<beanId>/batches', _getBatches);
    app.post('/api/v1/beans/<beanId>/batches', _createBatch);
    app.get('/api/v1/bean-batches', _getAllBatches);
    app.get('/api/v1/bean-batches/<id>', _getBatch);
    app.put('/api/v1/bean-batches/<id>', _updateBatch);
    app.delete('/api/v1/bean-batches/<id>', _deleteBatch);
  }

  Future<Response> _getBeans(Request req) async {
    try {
      final includeArchived =
          req.url.queryParameters['includeArchived'] == 'true';
      final beans = await _storage.getAllBeans(
        includeArchived: includeArchived,
      );
      return jsonOkConditional(req, beans.map((b) => b.toJson()).toList());
    } catch (e, st) {
      _log.severe('Error getting beans', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getBean(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final bean = await _storage.getBeanById(id);
      if (bean == null) {
        return jsonNotFound({'error': 'Bean not found'});
      }
      return jsonOk(bean.toJson());
    } catch (e, st) {
      _log.severe('Error getting bean $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _createBean(Request req) async {
    try {
      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;
      final bean = Bean.create(
        roaster: json['roaster'] as String,
        name: json['name'] as String,
        species: json['species'] as String?,
        decaf: json['decaf'] as bool? ?? false,
        decafProcess: json['decafProcess'] as String?,
        country: json['country'] as String?,
        region: json['region'] as String?,
        producer: json['producer'] as String?,
        variety: (json['variety'] as List?)?.cast<String>(),
        altitude: (json['altitude'] as List?)?.cast<int>(),
        processing: json['processing'] as String?,
        notes: json['notes'] as String?,
        extras: json['extras'] as Map<String, dynamic>?,
      );
      await _storage.insertBean(bean);
      return jsonCreated(bean.toJson());
    } on RequestBodyReadException {
      rethrow;
    } catch (e, st) {
      _log.severe('Error creating bean', e, st);
      return jsonBadRequest({'error': e.toString()});
    }
  }

  Future<Response> _updateBean(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final existing = await _storage.getBeanById(id);
      if (existing == null) {
        return jsonNotFound({'error': 'Bean not found'});
      }

      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;

      rejectExplicitNulls(json, const ['roaster', 'name', 'decaf', 'archived']);
      validatePatchFieldTypes(
        json,
        integerListFields: const ['altitude'],
        stringListFields: const ['variety'],
      );
      final updated = Bean.fromJson({
        ...existing.toJson(),
        ...json,
        'id': existing.id,
        'createdAt': existing.createdAt.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      });

      await _storage.updateBean(updated);
      return jsonOk(updated.toJson());
    } on RequestBodyReadException {
      rethrow;
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.toString()});
    } on TypeError catch (e) {
      return jsonBadRequest({'error': e.toString()});
    } catch (e, st) {
      _log.severe('Error updating bean $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _deleteBean(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      await _storage.deleteBean(id);
      return jsonOk({'success': true, 'id': id});
    } catch (e, st) {
      _log.severe('Error deleting bean $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getBatches(Request req, String beanId) async {
    beanId = Uri.decodeComponent(beanId);
    try {
      final includeArchived =
          req.url.queryParameters['includeArchived'] == 'true';
      final batches = await _storage.getBatchesForBean(
        beanId,
        includeArchived: includeArchived,
      );
      return jsonOkConditional(req, batches.map((b) => b.toJson()).toList());
    } catch (e, st) {
      _log.severe('Error getting batches for bean $beanId', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _getAllBatches(Request req) async {
    try {
      final includeArchived =
          req.url.queryParameters['includeArchived'] == 'true';
      final batches = await _storage.getAllBatches(
        includeArchived: includeArchived,
      );
      return jsonOkConditional(req, batches.map((b) => b.toJson()).toList());
    } catch (e, st) {
      _log.severe('Error getting batches', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _createBatch(Request req, String beanId) async {
    beanId = Uri.decodeComponent(beanId);
    try {
      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;
      final batch = BeanBatch.create(
        beanId: beanId,
        roastDate: json['roastDate'] != null
            ? DateTime.parse(json['roastDate'] as String)
            : null,
        roastLevel: json['roastLevel'] as String?,
        harvestDate: json['harvestDate'] as String?,
        qualityScore: (json['qualityScore'] as num?)?.toDouble(),
        price: (json['price'] as num?)?.toDouble(),
        currency: json['currency'] as String?,
        weight: (json['weight'] as num?)?.toDouble(),
        buyDate: json['buyDate'] != null
            ? DateTime.parse(json['buyDate'] as String)
            : null,
        openDate: json['openDate'] != null
            ? DateTime.parse(json['openDate'] as String)
            : null,
        bestBeforeDate: json['bestBeforeDate'] != null
            ? DateTime.parse(json['bestBeforeDate'] as String)
            : null,
        freezeDate: json['freezeDate'] != null
            ? DateTime.parse(json['freezeDate'] as String)
            : null,
        unfreezeDate: json['unfreezeDate'] != null
            ? DateTime.parse(json['unfreezeDate'] as String)
            : null,
        frozen: json['frozen'] as bool? ?? false,
        notes: json['notes'] as String?,
        extras: json['extras'] as Map<String, dynamic>?,
      );
      await _storage.insertBatch(batch);
      return jsonCreated(batch.toJson());
    } on RequestBodyReadException {
      rethrow;
    } catch (e, st) {
      _log.severe('Error creating batch for bean $beanId', e, st);
      return jsonBadRequest({'error': e.toString()});
    }
  }

  Future<Response> _getBatch(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final batch = await _storage.getBatchById(id);
      if (batch == null) {
        return jsonNotFound({'error': 'Batch not found'});
      }
      return jsonOk(batch.toJson());
    } catch (e, st) {
      _log.severe('Error getting batch $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _updateBatch(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      final existing = await _storage.getBatchById(id);
      if (existing == null) {
        return jsonNotFound({'error': 'Batch not found'});
      }

      final body = await readBoundedRequestBodyString(
        req,
        maxBytes: largeRequestBodyBytes,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;

      rejectExplicitNulls(json, const ['frozen', 'archived']);
      validatePatchFieldTypes(
        json,
        numberFields: const [
          'qualityScore',
          'price',
          'weight',
          'weightRemaining',
        ],
      );
      final updated = BeanBatch.fromJson({
        ...existing.toJson(),
        ...json,
        'id': existing.id,
        'beanId': existing.beanId,
        'createdAt': existing.createdAt.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      });

      await _storage.updateBatch(updated);
      return jsonOk(updated.toJson());
    } on RequestBodyReadException {
      rethrow;
    } on FormatException catch (e) {
      return jsonBadRequest({'error': e.toString()});
    } on TypeError catch (e) {
      return jsonBadRequest({'error': e.toString()});
    } catch (e, st) {
      _log.severe('Error updating batch $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }

  Future<Response> _deleteBatch(Request req, String id) async {
    id = Uri.decodeComponent(id);
    try {
      await _storage.deleteBatch(id);
      return jsonOk({'success': true, 'id': id});
    } catch (e, st) {
      _log.severe('Error deleting batch $id', e, st);
      return jsonError({'error': e.toString()});
    }
  }
}
