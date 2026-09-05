import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_hash.dart';
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
  late ProfileController controller;
  late _StubStorage storage;
  late Handler handler;

  Future<Response> postRawProfile(String body) async {
    return await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/v1/profiles'),
        body: body,
      ),
    );
  }

  Future<Response> putRawProfile(String id, String body) async {
    return await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/profiles/$id'),
        body: body,
      ),
    );
  }

  Future<Response> postProfile(Map<String, dynamic> body) async {
    return await postRawProfile(jsonEncode(body));
  }

  Future<Response> putProfile(String id, Map<String, dynamic> body) async {
    return await putRawProfile(id, jsonEncode(body));
  }

  setUp(() {
    storage = _StubStorage();
    controller = ProfileController(storage: storage);
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

  group('PUT /api/v1/profiles/<id>', () {
    test('applies tri-state metadata semantics', () async {
      final createResponse = await postProfile({
        'profile': profileWithoutMetadata(),
        'metadata': {'source': 'import'},
      });
      final created =
          jsonDecode(await createResponse.readAsString())
              as Map<String, dynamic>;
      final id = created['id'] as String;

      final preserved = await putProfile(id, {});
      expect(jsonDecode(await preserved.readAsString())['metadata'], {
        'source': 'import',
      });

      final cleared = await putProfile(id, {'metadata': null});
      expect(jsonDecode(await cleared.readAsString())['metadata'], isNull);

      final replaced = await putProfile(id, {
        'metadata': {'source': 'user'},
      });
      expect(jsonDecode(await replaced.readAsString())['metadata'], {
        'source': 'user',
      });
    });

    test('rejects explicit null for the non-nullable profile', () async {
      final createResponse = await postProfile({
        'profile': profileWithoutMetadata(),
      });
      final created =
          jsonDecode(await createResponse.readAsString())
              as Map<String, dynamic>;

      final response = await putProfile(created['id'] as String, {
        'profile': null,
      });

      expect(response.statusCode, 400);
    });
  });

  // Decal audit finding F-048 (server half). The device answered these exact
  // bytes with a 500 on POST and a 400 on PUT, because a limiter carrying only
  // a "value" threw a TypeError that only _handleUpdate caught.
  group('rangeless limiter (F-048)', () {
    String fixture(String name) =>
        File('test/fixtures/f048/$name').readAsStringSync();

    Map<String, dynamic> stepWithLimiter(dynamic limiter) => {
      'name': 'pour',
      'pump': 'pressure',
      'transition': 'fast',
      'volume': 100,
      'seconds': 30,
      'temperature': 93,
      'sensor': 'coffee',
      'pressure': 9,
      'limiter': limiter,
    };

    Future<String> seedRecord() async {
      final response = await postProfile({'profile': profileWithoutMetadata()});
      final created =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      return created['id'] as String;
    }

    test('POST accepts the device-verbatim body that returned 500', () async {
      // The captured body names a parent that existed in the device library.
      final parentProfile = Profile.fromJson(profileWithoutMetadata());
      final hashes = ProfileHash.calculateAll(parentProfile);
      await storage.store(
        ProfileRecord(
          id: 'profile:5ae9b2e3bfbeee965258',
          profile: parentProfile,
          metadataHash: hashes.metadataHash,
          compoundHash: hashes.compoundHash,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final response = await postRawProfile(fixture('e01_post_body.json'));

      expect(response.statusCode, 201);
      final record =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final steps =
          (record['profile'] as Map<String, dynamic>)['steps'] as List<dynamic>;
      expect((steps[0] as Map<String, dynamic>)['limiter'], {
        'value': 0.1,
        'range': 0.0,
      });
      expect((steps[1] as Map<String, dynamic>)['limiter'], isNull);
      expect((steps[2] as Map<String, dynamic>)['limiter'], {
        'value': 6.0,
        'range': 3.0,
      });
    });

    test('PUT accepts the device-verbatim body and re-addresses it', () async {
      final id = await seedRecord();

      final response = await putRawProfile(id, fixture('e01_put_body.json'));

      expect(response.statusCode, 200);
      final record =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(record['id'], isNot(equals(id)));
      final steps =
          (record['profile'] as Map<String, dynamic>)['steps'] as List<dynamic>;
      expect((steps[0] as Map<String, dynamic>)['limiter'], {
        'value': 0.1,
        'range': 0.0,
      });
    });

    test('the three captured poison shapes all save', () async {
      for (final limiter in [
        {'value': 0.1},
        {'value': 2.5},
        {'value': 0},
      ]) {
        final body = profileWithoutMetadata()
          ..['steps'] = <dynamic>[stepWithLimiter(limiter)];

        final response = await postProfile({'profile': body});

        expect(response.statusCode, 201, reason: 'limiter $limiter');
      }
    });

    test('POST and PUT answer identically for a valueless limiter', () async {
      final id = await seedRecord();
      final body = profileWithoutMetadata()
        ..['steps'] = <dynamic>[stepWithLimiter(<String, dynamic>{})];

      final post = await postProfile({'profile': body});
      final put = await putProfile(id, {'profile': body});
      final postBody = await post.readAsString();
      final putBody = await put.readAsString();

      expect(post.statusCode, 400);
      expect(put.statusCode, 400);
      expect(postBody, equals(putBody));
      expect(postBody, contains(r'limiter \"value\"'));
    });

    test('POST and PUT answer identically for a residual TypeError', () async {
      final id = await seedRecord();
      final body = profileWithoutMetadata()
        ..['steps'] = <dynamic>[
          stepWithLimiter({'value': 1, 'range': 0.6})..['transition'] = null,
        ];

      final post = await postProfile({'profile': body});
      final put = await putProfile(id, {'profile': body});
      final postBody = await post.readAsString();
      final putBody = await put.readAsString();

      expect(post.statusCode, 400);
      expect(put.statusCode, 400);
      expect(postBody, equals(putBody));
    });
  });
}
