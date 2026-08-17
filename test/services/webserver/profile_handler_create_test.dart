import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

class _StubStorage implements ProfileStorageService {
  final Map<String, ProfileRecord> _records = {};

  @override
  Future<void> initialize() async {}
  @override
  Future<void> store(ProfileRecord record) async =>
      _records[record.id] = record;
  @override
  Future<ProfileRecord?> get(String id) async => _records[id];
  @override
  Future<List<ProfileRecord>> getAll({Visibility? visibility}) async =>
      _records.values.toList();
  @override
  Future<void> update(ProfileRecord record) async =>
      _records[record.id] = record;
  @override
  Future<void> replace(String oldId, ProfileRecord replacement) async {
    _records[replacement.id] = replacement;
    _records.remove(oldId);
  }

  @override
  Future<void> delete(String id) async => _records.remove(id);
  @override
  Future<bool> exists(String id) async => _records.containsKey(id);
  @override
  Future<List<String>> getAllIds() async => _records.keys.toList();
  @override
  Future<List<ProfileRecord>> getByParentId(String parentId) async => const [];
  @override
  Future<void> storeAll(List<ProfileRecord> records) async {
    for (final r in records) {
      _records[r.id] = r;
    }
  }

  @override
  Future<void> clear() async => _records.clear();
  @override
  Future<int> count({Visibility? visibility}) async => _records.length;
}

void main() {
  late Handler handler;

  Future<Response> postProfile(Map<String, dynamic> body) async {
    return await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/profiles'),
        body: jsonEncode(body),
      ),
    );
  }

  setUp(() {
    final controller = ProfileController(storage: _StubStorage());
    final profileHandler = ProfileHandler(controller: controller);
    final app = Router().plus;
    profileHandler.addRoutes(app);
    handler = app.call;
  });

  Map<String, dynamic> profileWithoutMetadata() => {
    'version': '2',
    'title': 'Imported profile',
    'beverage_type': 'espresso',
    'steps': <dynamic>[
      {
        'name': 'pour',
        'pump': 'pressure',
        'transition': 'fast',
        'volume': 100,
        'seconds': 30,
        'temperature': 93,
        'sensor': 'coffee',
        'pressure': 9,
      },
    ],
    'tank_temperature': 93.0,
    'target_volume_count_start': 0,
  };

  group('POST /api/v1/profiles', () {
    test('creates a profile when notes and author are omitted', () async {
      final response = await postProfile({'profile': profileWithoutMetadata()});

      expect(response.statusCode, 201);
      final record =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final profile = record['profile'] as Map<String, dynamic>;
      expect(profile['notes'], equals(''));
      expect(profile['author'], equals(''));
      expect(profile['title'], equals('Imported profile'));
    });

    test('returns 400 (not 500) when title is missing', () async {
      final body = profileWithoutMetadata()..remove('title');

      final response = await postProfile({'profile': body});

      expect(response.statusCode, 400);
    });

    test('returns 400 (not 500) when steps is empty', () async {
      final body = profileWithoutMetadata()..['steps'] = <dynamic>[];

      final response = await postProfile({'profile': body});

      expect(response.statusCode, 400);
    });

    test('returns 400 (not 500) when steps is missing', () async {
      final body = profileWithoutMetadata()..remove('steps');

      final response = await postProfile({'profile': body});

      expect(response.statusCode, 400);
    });

    test('returns 400 (not 500) when tank_temperature is missing', () async {
      final body = profileWithoutMetadata()..remove('tank_temperature');

      final response = await postProfile({'profile': body});

      expect(response.statusCode, 400);
    });

    test(
      'returns 400 (not 500) when target_volume_count_start is missing',
      () async {
        final body = profileWithoutMetadata()
          ..remove('target_volume_count_start');

        final response = await postProfile({'profile': body});

        expect(response.statusCode, 400);
      },
    );

    test(
      'returns 400 (not 500) when a required number is unparseable',
      () async {
        final body = profileWithoutMetadata()..['tank_temperature'] = 'hot';

        final response = await postProfile({'profile': body});

        expect(response.statusCode, 400);
      },
    );
  });
}
