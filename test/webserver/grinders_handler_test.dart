import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/grinder.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/webserver/grinders_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

class MockGrinderStorageService implements GrinderStorageService {
  final List<Grinder> grinders = [];

  @override
  Future<List<Grinder>> getAllGrinders({bool includeArchived = false}) async {
    if (includeArchived) return List.of(grinders);
    return grinders.where((g) => !g.archived).toList();
  }

  @override
  Stream<List<Grinder>> watchAllGrinders({bool includeArchived = false}) {
    throw UnimplementedError();
  }

  @override
  Future<Grinder?> getGrinderById(String id) async {
    return grinders.where((g) => g.id == id).firstOrNull;
  }

  @override
  Future<void> insertGrinder(Grinder grinder) async {
    grinders.add(grinder);
  }

  @override
  Future<void> updateGrinder(Grinder grinder) async {
    grinders.removeWhere((g) => g.id == grinder.id);
    grinders.add(grinder);
  }

  @override
  Future<void> deleteGrinder(String id) async {
    grinders.removeWhere((g) => g.id == id);
  }
}

void main() {
  late MockGrinderStorageService storage;
  late Handler handler;

  setUp(() {
    storage = MockGrinderStorageService();
    final grindersHandler = GrindersHandler(storage: storage);
    final app = Router().plus;
    grindersHandler.addRoutes(app);
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

  group('GrindersHandler', () {
    test('GET /api/v1/grinders returns empty list', () async {
      final response = await sendGet('/api/v1/grinders');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, isEmpty);
    });

    test('POST /api/v1/grinders creates a grinder', () async {
      final response = await sendPost('/api/v1/grinders', {
        'model': 'Niche Zero',
        'burrs': 'Mazzer',
        'burrSize': 63.0,
        'burrType': 'conical',
        'settingType': 'numeric',
      });
      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      expect(body['model'], 'Niche Zero');
      expect(body['burrs'], 'Mazzer');
      expect(body['burrSize'], 63.0);
      expect(body['burrType'], 'conical');
      expect(body['settingType'], 'numeric');
      expect(body['id'], isNotEmpty);
    });

    test('GET /api/v1/grinders returns created grinders', () async {
      await sendPost('/api/v1/grinders', {'model': 'Niche Zero'});
      await sendPost('/api/v1/grinders', {'model': 'Lagom P64'});

      final response = await sendGet('/api/v1/grinders');
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, hasLength(2));
    });

    test('GET /api/v1/grinders/<id> returns a specific grinder', () async {
      final createRes = await sendPost('/api/v1/grinders', {
        'model': 'Niche Zero',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final response = await sendGet('/api/v1/grinders/$id');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['id'], id);
      expect(body['model'], 'Niche Zero');
    });

    test('GET /api/v1/grinders/<id> returns 404 for missing grinder', () async {
      final response = await sendGet('/api/v1/grinders/nonexistent');
      expect(response.statusCode, 404);
    });

    test('PUT /api/v1/grinders/<id> updates a grinder', () async {
      final createRes = await sendPost('/api/v1/grinders', {
        'model': 'Niche Zero',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final response = await sendPut('/api/v1/grinders/$id', {
        'model': 'Niche Zero v2',
        'notes': 'Upgraded burrs',
      });
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['model'], 'Niche Zero v2');
      expect(body['notes'], 'Upgraded burrs');
    });

    test('PUT /api/v1/grinders/<id> returns 404 for missing grinder', () async {
      final response = await sendPut('/api/v1/grinders/nonexistent', {
        'model': 'Test',
      });
      expect(response.statusCode, 404);
    });

    test('DELETE /api/v1/grinders/<id> deletes a grinder', () async {
      final createRes = await sendPost('/api/v1/grinders', {
        'model': 'Niche Zero',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final response = await sendDelete('/api/v1/grinders/$id');
      expect(response.statusCode, 200);

      final getRes = await sendGet('/api/v1/grinders/$id');
      expect(getRes.statusCode, 404);
    });

    test('GET /api/v1/grinders sets ETag and honours If-None-Match', () async {
      final empty = await sendGet('/api/v1/grinders');
      expect(empty.statusCode, 200);
      expect(empty.headers['etag'], isNotNull);

      await sendPost('/api/v1/grinders', {
        'manufacturer': 'Niche',
        'model': 'Zero',
      });
      final populated = await sendGet('/api/v1/grinders');
      final etag = populated.headers['etag'];
      expect(etag, isNotNull);
      expect(etag, isNot(empty.headers['etag']));

      final cached = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/grinders'),
          headers: {'If-None-Match': etag!},
        ),
      );
      expect(cached.statusCode, 304);
      expect(cached.headers['etag'], etag);
      expect(await cached.readAsString(), isEmpty);
    });

    test('GET /api/v1/grinders filters out archived by default', () async {
      final createRes = await sendPost('/api/v1/grinders', {
        'model': 'Niche Zero',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      await sendPut('/api/v1/grinders/$id', {'archived': true});

      final response = await sendGet('/api/v1/grinders');
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, isEmpty);

      final archivedRes = await sendGet(
        '/api/v1/grinders?includeArchived=true',
      );
      final archivedBody = jsonDecode(await archivedRes.readAsString()) as List;
      expect(archivedBody, hasLength(1));
    });

    test('POST /api/v1/grinders with preset settingValues', () async {
      final response = await sendPost('/api/v1/grinders', {
        'model': 'Lagom Mini',
        'settingType': 'preset',
        'settingValues': ['fine', 'medium', 'coarse'],
      });
      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      expect(body['settingType'], 'preset');
      expect(body['settingValues'], ['fine', 'medium', 'coarse']);
    });
  });
}
