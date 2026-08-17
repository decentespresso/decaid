import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

class _StubStorage implements ProfileStorageService {
  @override
  Future<void> initialize() async {}
  @override
  Future<void> store(ProfileRecord record) async {}
  @override
  Future<ProfileRecord?> get(String id) async => null;
  @override
  Future<List<ProfileRecord>> getAll({Visibility? visibility}) async =>
      const [];
  @override
  Future<void> update(ProfileRecord record) async {}
  @override
  Future<void> replace(String oldId, ProfileRecord replacement) async {}

  @override
  Future<void> delete(String id) async {}
  @override
  Future<bool> exists(String id) async => false;
  @override
  Future<List<String>> getAllIds() async => const [];
  @override
  Future<List<ProfileRecord>> getByParentId(String parentId) async => const [];
  @override
  Future<void> storeAll(List<ProfileRecord> records) async {}
  @override
  Future<void> clear() async {}
  @override
  Future<int> count({Visibility? visibility}) async => 0;
}

class _ListDefaultsStub extends ProfileController {
  _ListDefaultsStub({required this.fixture}) : super(storage: _StubStorage());

  final List<Map<String, dynamic>> fixture;

  @override
  Future<List<Map<String, dynamic>>> listDefaults() async => fixture;
}

void main() {
  late Handler handler;

  Future<Response> sendGet(String path) async {
    return await handler(Request('GET', Uri.parse('http://localhost$path')));
  }

  void wireHandler(List<Map<String, dynamic>> fixture) {
    final controller = _ListDefaultsStub(fixture: fixture);
    final profileHandler = ProfileHandler(controller: controller);
    final app = Router().plus;
    profileHandler.addRoutes(app);
    handler = app.call;
  }

  group('GET /api/v1/profiles/defaults', () {
    test('returns array of default profiles with full metadata', () async {
      wireHandler([
        {
          'filename': 'Default1.json',
          'title': 'Default 1',
          'author': 'Decent',
          'notes': 'Bundled default',
          'beverageType': 'espresso',
        },
        {
          'filename': 'Filter_20.json',
          'title': 'Filter 20',
          'author': 'Decent',
          'notes': '',
          'beverageType': 'filter',
        },
      ]);

      final response = await sendGet('/api/v1/profiles/defaults');

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final body = jsonDecode(await response.readAsString()) as List;
      expect(body.length, 2);
      expect(body[0], {
        'filename': 'Default1.json',
        'title': 'Default 1',
        'author': 'Decent',
        'notes': 'Bundled default',
        'beverageType': 'espresso',
      });
      expect(body[1]['filename'], 'Filter_20.json');
    });

    test('returns empty array when no defaults are bundled', () async {
      wireHandler([]);

      final response = await sendGet('/api/v1/profiles/defaults');

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, isEmpty);
    });

    test('does not collide with /{id} route', () async {
      wireHandler([
        {
          'filename': 'Only.json',
          'title': 'Only',
          'author': '',
          'notes': '',
          'beverageType': 'espresso',
        },
      ]);

      final response = await sendGet('/api/v1/profiles/defaults');

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body.first['filename'], 'Only.json');
    });
  });
}
