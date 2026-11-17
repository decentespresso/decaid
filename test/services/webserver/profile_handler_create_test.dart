import 'dart:convert';
import 'dart:io';

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
  late ProfileController controller;
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
    controller = ProfileController(storage: _StubStorage());
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
      final created = jsonDecode(
        await createResponse.readAsString(),
      ) as Map<String, dynamic>;
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
      final created = jsonDecode(
        await createResponse.readAsString(),
      ) as Map<String, dynamic>;

      final response = await putProfile(created['id'] as String, {
        'profile': null,
      });

      expect(response.statusCode, 400);
    });
  });

  group('a limiter with no range', () {
    const rangeRefusal = {
      'error': 'Invalid request',
      'message': 'FormatException: limiter "range" must be a number',
    };
    const valueRefusal = {
      'error': 'Invalid request',
      'message': 'FormatException: limiter "value" must be a number',
    };

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

    Map<String, dynamic> profileWithStepLimiter(dynamic limiter) =>
        profileWithoutMetadata()
          ..['steps'] = <dynamic>[stepWithLimiter(limiter)];

    Future<String> seedRecord() async {
      final response = await postProfile({'profile': profileWithoutMetadata()});
      final created =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      return created['id'] as String;
    }

    Future<Map<String, dynamic>> decode(Response response) async =>
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    test('POST refuses the device-verbatim body that returned 500', () async {
      final response = await postRawProfile(fixture('e01_post_body.json'));

      expect(response.statusCode, 400);
      expect(await decode(response), rangeRefusal);
    });

    test('PUT refuses the device-verbatim body with the POST text', () async {
      final id = await seedRecord();

      final response = await putRawProfile(id, fixture('e01_put_body.json'));

      expect(response.statusCode, 400);
      expect(await decode(response), rangeRefusal);
    });

    test('the three captured poison shapes are all refused', () async {
      final id = await seedRecord();
      for (final limiter in [
        {'value': 0.1},
        {'value': 2.5},
        {'value': 0},
      ]) {
        final body = {'profile': profileWithStepLimiter(limiter)};

        final post = await postProfile(body);
        final put = await putProfile(id, body);

        expect(post.statusCode, 400, reason: 'POST limiter $limiter');
        expect(put.statusCode, 400, reason: 'PUT limiter $limiter');
        expect(await decode(post), rangeRefusal, reason: 'POST $limiter');
        expect(await decode(put), rangeRefusal, reason: 'PUT $limiter');
      }
    });

    final refusedForms = <String, (Map<String, dynamic>, Map<String, String>)>{
      '(a) {value: 6}': (const {'value': 6}, rangeRefusal),
      '(c) {value: 6, range: null}': (
        const {'value': 6, 'range': null},
        rangeRefusal,
      ),
      '(d) {range: 1}': (const {'range': 1}, valueRefusal),
      '(e) {value: null, range: 1}': (
        const {'value': null, 'range': 1},
        valueRefusal,
      ),
      '(f) {value: 6, range: "x"}': (
        const {'value': 6, 'range': 'x'},
        rangeRefusal,
      ),
    };

    for (final MapEntry(key: form, value: (limiter, refusal))
        in refusedForms.entries) {
      test(
        'form $form: POST and PUT both answer 400 with the same text',
        () async {
          final id = await seedRecord();
          final body = {'profile': profileWithStepLimiter(limiter)};

          final post = await postProfile(body);
          final put = await putProfile(id, body);

          expect(post.statusCode, 400);
          expect(put.statusCode, 400);
          expect(await decode(post), refusal);
          expect(await decode(put), refusal);
        },
      );
    }

    test('form (b) {value: 6, range: 0}: POST and PUT store range 0', () async {
      final id = await seedRecord();
      final body = {
        'profile': profileWithStepLimiter({'value': 6, 'range': 0}),
      };

      final post = await postProfile(body);
      final put = await putProfile(id, body);

      expect(post.statusCode, 201);
      expect(put.statusCode, 200);
      for (final response in [post, put]) {
        final record = await decode(response);
        final steps =
            (record['profile'] as Map<String, dynamic>)['steps']
                as List<dynamic>;
        expect((steps.single as Map<String, dynamic>)['limiter'], {
          'value': 6.0,
          'range': 0.0,
        });
      }
    });

    test('a boolean range gets the named refusal on POST and PUT', () async {
      final id = await seedRecord();
      final body = {
        'profile': profileWithStepLimiter({'value': 6, 'range': true}),
      };

      final post = await postProfile(body);
      final put = await putProfile(id, body);

      expect(post.statusCode, 400);
      expect(put.statusCode, 400);
      expect(await decode(post), rangeRefusal);
      expect(await decode(put), rangeRefusal);
    });

    for (final limiter in <dynamic>[5, 'x', <dynamic>[]]) {
      test('a non-object limiter $limiter is a 400 on POST and PUT', () async {
        final id = await seedRecord();
        final body = {'profile': profileWithStepLimiter(limiter)};

        final post = await postProfile(body);
        final put = await putProfile(id, body);
        final postBody = await post.readAsString();
        final putBody = await put.readAsString();

        expect(post.statusCode, 400);
        expect(put.statusCode, 400);
        expect(postBody, equals(putBody));
      });
    }

    test('POST and PUT answer identically for a valueless limiter', () async {
      final id = await seedRecord();
      final body = {'profile': profileWithStepLimiter(<String, dynamic>{})};

      final post = await postProfile(body);
      final put = await putProfile(id, body);

      expect(post.statusCode, 400);
      expect(put.statusCode, 400);
      expect(await decode(post), valueRefusal);
      expect(await decode(put), valueRefusal);
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
