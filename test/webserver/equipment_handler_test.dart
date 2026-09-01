import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/equipment.dart';
import 'package:reaprime/src/services/storage/equipment_storage_service.dart';
import 'package:reaprime/src/services/webserver/equipment_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

class MockEquipmentStorageService implements EquipmentStorageService {
  final List<Equipment> equipment = [];

  @override
  Future<List<Equipment>> getAllEquipment({
    bool includeArchived = false,
    EquipmentType? type,
  }) async {
    var result = includeArchived
        ? List.of(equipment)
        : equipment.where((e) => !e.archived).toList();
    if (type != null) {
      result = result.where((e) => e.type == type).toList();
    }
    return result;
  }

  @override
  Stream<List<Equipment>> watchAllEquipment({bool includeArchived = false}) {
    throw UnimplementedError();
  }

  @override
  Future<Equipment?> getEquipmentById(String id) async {
    return equipment.where((e) => e.id == id).firstOrNull;
  }

  @override
  Future<void> insertEquipment(Equipment item) async {
    equipment.add(item);
  }

  @override
  Future<void> updateEquipment(Equipment item) async {
    equipment.removeWhere((e) => e.id == item.id);
    equipment.add(item);
  }

  @override
  Future<void> deleteEquipment(String id) async {
    equipment.removeWhere((e) => e.id == id);
  }
}

void main() {
  late MockEquipmentStorageService storage;
  late Handler handler;

  setUp(() {
    storage = MockEquipmentStorageService();
    final equipmentHandler = EquipmentHandler(storage: storage);
    final app = Router().plus;
    equipmentHandler.addRoutes(app);
    handler = app.call;
  });

  Future<Response> sendGet(String path) async {
    return await handler(Request('GET', Uri.parse('http://localhost$path')));
  }

  Future<Response> sendPost(String path, Map<String, dynamic> body) async {
    return await handler(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      ),
    );
  }

  Future<Response> sendPut(String path, Map<String, dynamic> body) async {
    return await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      ),
    );
  }

  Future<Response> sendDelete(String path) async {
    return await handler(Request('DELETE', Uri.parse('http://localhost$path')));
  }

  group('EquipmentHandler', () {
    test('GET /api/v1/equipment returns empty list', () async {
      final response = await sendGet('/api/v1/equipment');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, isEmpty);
    });

    test('POST /api/v1/equipment creates a basket', () async {
      final response = await sendPost('/api/v1/equipment', {
        'type': 'basket',
        'name': 'IMS Superfine 18g',
        'style': 'double',
        'diameterMm': 58.0,
      });
      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      expect(body['type'], 'basket');
      expect(body['name'], 'IMS Superfine 18g');
      expect(body['style'], 'double');
      expect(body['diameterMm'], 58.0);
      expect(body['id'], isNotEmpty);
    });

    test('POST /api/v1/equipment defaults type to other when omitted', () async {
      final response = await sendPost('/api/v1/equipment', {
        'name': 'Unlabelled tool',
      });
      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      expect(body['type'], 'other');
    });

    test('GET /api/v1/equipment filters by type', () async {
      await sendPost('/api/v1/equipment', {
        'type': 'basket',
        'name': 'Basket A',
      });
      await sendPost('/api/v1/equipment', {
        'type': 'portafilter',
        'name': 'Portafilter A',
      });

      final response = await sendGet('/api/v1/equipment?type=basket');
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, hasLength(1));
      expect(body.first['type'], 'basket');
    });

    test('GET /api/v1/equipment/<id> returns specific equipment', () async {
      final createRes = await sendPost('/api/v1/equipment', {
        'type': 'basket',
        'name': 'IMS Superfine 18g',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final response = await sendGet('/api/v1/equipment/$id');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['id'], id);
      expect(body['name'], 'IMS Superfine 18g');
    });

    test('GET /api/v1/equipment/<id> returns 404 for missing equipment', () async {
      final response = await sendGet('/api/v1/equipment/nonexistent');
      expect(response.statusCode, 404);
    });

    test('PUT /api/v1/equipment/<id> updates equipment', () async {
      final createRes = await sendPost('/api/v1/equipment', {
        'type': 'basket',
        'name': 'IMS Superfine 18g',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final response = await sendPut('/api/v1/equipment/$id', {
        'name': 'IMS Superfine 20g',
        'notes': 'Swapped for a bigger dose',
      });
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['name'], 'IMS Superfine 20g');
      expect(body['notes'], 'Swapped for a bigger dose');
    });

    test(
      'PUT /api/v1/equipment/<id> applies tri-state patch semantics',
      () async {
        final createRes = await sendPost('/api/v1/equipment', {
          'type': 'basket',
          'name': 'IMS Superfine 18g',
          'notes': 'Original',
        });
        final created = jsonDecode(await createRes.readAsString());
        final id = created['id'];

        final preserved = await sendPut('/api/v1/equipment/$id', {
          'style': 'double',
        });
        expect(
          jsonDecode(await preserved.readAsString())['notes'],
          'Original',
        );

        final cleared = await sendPut('/api/v1/equipment/$id', {
          'notes': null,
        });
        expect(
          (jsonDecode(await cleared.readAsString()) as Map).containsKey(
            'notes',
          ),
          isFalse,
        );

        final rejected = await sendPut('/api/v1/equipment/$id', {
          'name': null,
        });
        expect(rejected.statusCode, 400);
      },
    );

    test('PUT /api/v1/equipment/<id> returns 404 for missing equipment', () async {
      final response = await sendPut('/api/v1/equipment/nonexistent', {
        'name': 'Test',
      });
      expect(response.statusCode, 404);
    });

    test('DELETE /api/v1/equipment/<id> deletes equipment', () async {
      final createRes = await sendPost('/api/v1/equipment', {
        'type': 'basket',
        'name': 'IMS Superfine 18g',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final response = await sendDelete('/api/v1/equipment/$id');
      expect(response.statusCode, 200);

      final getRes = await sendGet('/api/v1/equipment/$id');
      expect(getRes.statusCode, 404);
    });

    test('GET /api/v1/equipment sets ETag and honours If-None-Match', () async {
      final empty = await sendGet('/api/v1/equipment');
      expect(empty.statusCode, 200);
      expect(empty.headers['etag'], isNotNull);

      await sendPost('/api/v1/equipment', {
        'type': 'basket',
        'name': 'IMS Superfine 18g',
      });
      final populated = await sendGet('/api/v1/equipment');
      final etag = populated.headers['etag'];
      expect(etag, isNotNull);
      expect(etag, isNot(empty.headers['etag']));

      final cached = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/equipment'),
          headers: {'If-None-Match': etag!},
        ),
      );
      expect(cached.statusCode, 304);
      expect(cached.headers['etag'], etag);
      expect(await cached.readAsString(), isEmpty);
    });

    test('GET /api/v1/equipment filters out archived by default', () async {
      final createRes = await sendPost('/api/v1/equipment', {
        'type': 'basket',
        'name': 'IMS Superfine 18g',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      await sendPut('/api/v1/equipment/$id', {'archived': true});

      final response = await sendGet('/api/v1/equipment');
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, isEmpty);

      final archivedRes = await sendGet(
        '/api/v1/equipment?includeArchived=true',
      );
      final archivedBody = jsonDecode(await archivedRes.readAsString()) as List;
      expect(archivedBody, hasLength(1));
    });
  });
}
