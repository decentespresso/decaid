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

class _ExportStub extends ProfileController {
  _ExportStub({required this.fixture}) : super(storage: _StubStorage());

  final List<Map<String, dynamic>> fixture;
  final List<String> getCalls = [];
  int exportCalls = 0;
  bool? includeHidden;
  bool? includeDeleted;

  @override
  Future<ProfileRecord?> get(String id) async {
    getCalls.add(id);
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> exportProfiles({
    bool includeHidden = false,
    bool includeDeleted = false,
  }) async {
    exportCalls++;
    this.includeHidden = includeHidden;
    this.includeDeleted = includeDeleted;
    return fixture;
  }
}

void main() {
  late _ExportStub controller;
  late Handler handler;

  Future<Response> sendGet(String path) async {
    return handler(Request('GET', Uri.parse('http://localhost$path')));
  }

  setUp(() {
    controller = _ExportStub(
      fixture: [
        {'id': 'profile-1', 'title': 'Morning espresso'},
      ],
    );
    final profileHandler = ProfileHandler(controller: controller);
    final app = Router().plus;
    profileHandler.addRoutes(app);
    handler = app.call;
  });

  test('dispatches export before the profile ID route', () async {
    final response = await sendGet('/api/v1/profiles/export');

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], contains('application/json'));
    expect(
      response.headers['content-disposition'],
      contains('filename="profiles_export.json"'),
    );
    expect(jsonDecode(await response.readAsString()), controller.fixture);
    expect(controller.exportCalls, 1);
    expect(controller.includeHidden, isFalse);
    expect(controller.includeDeleted, isFalse);
    expect(controller.getCalls, isEmpty);
  });

  test('passes export query flags to the controller', () async {
    final response = await sendGet(
      '/api/v1/profiles/export?includeHidden=true&includeDeleted=true',
    );

    expect(response.statusCode, 200);
    expect(controller.includeHidden, isTrue);
    expect(controller.includeDeleted, isTrue);
    expect(controller.getCalls, isEmpty);
  });
}
