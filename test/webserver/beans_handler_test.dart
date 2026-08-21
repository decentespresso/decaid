import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/bean.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/webserver/beans_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

class MockBeanStorageService implements BeanStorageService {
  final List<Bean> beans = [];
  final List<BeanBatch> batches = [];

  @override
  Future<List<Bean>> getAllBeans({bool includeArchived = false}) async {
    if (includeArchived) return List.of(beans);
    return beans.where((b) => !b.archived).toList();
  }

  @override
  Stream<List<Bean>> watchAllBeans({bool includeArchived = false}) {
    throw UnimplementedError();
  }

  @override
  Future<Bean?> getBeanById(String id) async {
    return beans.where((b) => b.id == id).firstOrNull;
  }

  @override
  Future<void> insertBean(Bean bean) async {
    beans.add(bean);
  }

  @override
  Future<void> updateBean(Bean bean) async {
    beans.removeWhere((b) => b.id == bean.id);
    beans.add(bean);
  }

  @override
  Future<void> deleteBean(String id) async {
    beans.removeWhere((b) => b.id == id);
  }

  @override
  Future<List<BeanBatch>> getAllBatches({bool includeArchived = false}) async {
    if (includeArchived) return List.of(batches);
    final activeBeanIds = beans
        .where((bean) => !bean.archived)
        .map((bean) => bean.id)
        .toSet();
    return batches
        .where(
          (batch) => !batch.archived && activeBeanIds.contains(batch.beanId),
        )
        .toList();
  }

  @override
  Future<List<BeanBatch>> getBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) async {
    final filtered = batches.where((b) => b.beanId == beanId);
    if (includeArchived) return filtered.toList();
    return filtered.where((b) => !b.archived).toList();
  }

  @override
  Stream<List<BeanBatch>> watchBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<BeanBatch?> getBatchById(String id) async {
    return batches.where((b) => b.id == id).firstOrNull;
  }

  @override
  Future<void> insertBatch(BeanBatch batch) async {
    batches.add(batch);
  }

  @override
  Future<void> updateBatch(BeanBatch batch) async {
    batches.removeWhere((b) => b.id == batch.id);
    batches.add(batch);
  }

  @override
  Future<void> deleteBatch(String id) async {
    batches.removeWhere((b) => b.id == id);
  }

  @override
  Future<void> decrementBatchWeight(String batchId, double amount) async {
    final idx = batches.indexWhere((b) => b.id == batchId);
    if (idx >= 0) {
      final batch = batches[idx];
      final remaining = ((batch.weightRemaining ?? batch.weight ?? 0) - amount)
          .clamp(0.0, double.infinity)
          .toDouble();
      batches[idx] = batch.copyWith(weightRemaining: remaining);
    }
  }
}

void main() {
  late MockBeanStorageService storage;
  late Handler handler;

  setUp(() {
    storage = MockBeanStorageService();
    final beansHandler = BeansHandler(storage: storage);
    final app = Router().plus;
    beansHandler.addRoutes(app);
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

  group('BeansHandler - Beans', () {
    test('GET /api/v1/beans returns empty list', () async {
      final response = await sendGet('/api/v1/beans');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, isEmpty);
    });

    test('POST /api/v1/beans creates a bean', () async {
      final response = await sendPost('/api/v1/beans', {
        'roaster': 'Sey',
        'name': 'Gichathaini',
        'country': 'Kenya',
      });
      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      expect(body['roaster'], 'Sey');
      expect(body['name'], 'Gichathaini');
      expect(body['country'], 'Kenya');
      expect(body['id'], isNotEmpty);
    });

    test('GET /api/v1/beans returns created beans', () async {
      await sendPost('/api/v1/beans', {
        'roaster': 'Sey',
        'name': 'Gichathaini',
      });
      await sendPost('/api/v1/beans', {
        'roaster': 'George Howell',
        'name': 'Mamuto AA',
      });

      final response = await sendGet('/api/v1/beans');
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, hasLength(2));
    });

    test('GET /api/v1/beans/<id> returns a specific bean', () async {
      final createRes = await sendPost('/api/v1/beans', {
        'roaster': 'Sey',
        'name': 'Gichathaini',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final response = await sendGet('/api/v1/beans/$id');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['id'], id);
      expect(body['roaster'], 'Sey');
    });

    test('GET /api/v1/beans/<id> returns 404 for missing bean', () async {
      final response = await sendGet('/api/v1/beans/nonexistent');
      expect(response.statusCode, 404);
    });

    test('PUT /api/v1/beans/<id> updates a bean', () async {
      final createRes = await sendPost('/api/v1/beans', {
        'roaster': 'Sey',
        'name': 'Gichathaini',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final response = await sendPut('/api/v1/beans/$id', {
        'name': 'Gichathaini AA',
        'country': 'Kenya',
      });
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['name'], 'Gichathaini AA');
      expect(body['country'], 'Kenya');
      expect(body['roaster'], 'Sey');
    });

    test('PUT /api/v1/beans/<id> applies tri-state patch semantics', () async {
      final createRes = await sendPost('/api/v1/beans', {
        'roaster': 'Sey',
        'name': 'Gichathaini',
        'country': 'Kenya',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final preserved = await sendPut('/api/v1/beans/$id', {
        'name': 'Gichathaini AA',
      });
      expect(jsonDecode(await preserved.readAsString())['country'], 'Kenya');

      final cleared = await sendPut('/api/v1/beans/$id', {'country': null});
      expect(
        (jsonDecode(await cleared.readAsString()) as Map).containsKey(
          'country',
        ),
        isFalse,
      );

      final replaced = await sendPut('/api/v1/beans/$id', {
        'country': 'Ethiopia',
      });
      expect(jsonDecode(await replaced.readAsString())['country'], 'Ethiopia');

      final rejected = await sendPut('/api/v1/beans/$id', {'roaster': null});
      expect(rejected.statusCode, 400);
    });

    test(
      'PUT /api/v1/beans/<id> rejects malformed lists without mutation',
      () async {
        final createRes = await sendPost('/api/v1/beans', {
          'roaster': 'Sey',
          'name': 'Gichathaini',
          'variety': ['Heirloom'],
          'altitude': [1800, 2200],
        });
        final created = jsonDecode(await createRes.readAsString());
        final id = created['id'];

        for (final patch in [
          {
            'altitude': ['1800', 2200],
          },
          {
            'altitude': [1800.5, 2200],
          },
          {
            'variety': [1],
          },
        ]) {
          final response = await sendPut('/api/v1/beans/$id', patch);
          expect(response.statusCode, 400, reason: '$patch');

          final stored = jsonDecode(
            await (await sendGet('/api/v1/beans/$id')).readAsString(),
          );
          expect(stored['altitude'], [1800, 2200], reason: '$patch');
          expect(stored['variety'], ['Heirloom'], reason: '$patch');
        }
      },
    );

    test('PUT /api/v1/beans/<id> returns 404 for missing bean', () async {
      final response = await sendPut('/api/v1/beans/nonexistent', {
        'name': 'Test',
      });
      expect(response.statusCode, 404);
    });

    test('DELETE /api/v1/beans/<id> deletes a bean', () async {
      final createRes = await sendPost('/api/v1/beans', {
        'roaster': 'Sey',
        'name': 'Gichathaini',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      final response = await sendDelete('/api/v1/beans/$id');
      expect(response.statusCode, 200);

      final getRes = await sendGet('/api/v1/beans/$id');
      expect(getRes.statusCode, 404);
    });

    test('GET /api/v1/beans sets ETag and honours If-None-Match', () async {
      final empty = await sendGet('/api/v1/beans');
      expect(empty.statusCode, 200);
      expect(empty.headers['etag'], isNotNull);

      await sendPost('/api/v1/beans', {'roaster': 'Sey', 'name': 'X'});
      final populated = await sendGet('/api/v1/beans');
      final etag = populated.headers['etag'];
      expect(etag, isNotNull);
      expect(etag, isNot(empty.headers['etag']));

      final cached = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/beans'),
          headers: {'If-None-Match': etag!},
        ),
      );
      expect(cached.statusCode, 304);
      expect(cached.headers['etag'], etag);
      expect(await cached.readAsString(), isEmpty);
    });

    test('GET /api/v1/beans filters out archived by default', () async {
      final createRes = await sendPost('/api/v1/beans', {
        'roaster': 'Sey',
        'name': 'Gichathaini',
      });
      final created = jsonDecode(await createRes.readAsString());
      final id = created['id'];

      await sendPut('/api/v1/beans/$id', {'archived': true});

      final response = await sendGet('/api/v1/beans');
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, isEmpty);

      final archivedRes = await sendGet('/api/v1/beans?includeArchived=true');
      final archivedBody = jsonDecode(await archivedRes.readAsString()) as List;
      expect(archivedBody, hasLength(1));
    });
  });

  group('BeansHandler - Batches', () {
    late String beanId;

    setUp(() async {
      final createRes = await sendPost('/api/v1/beans', {
        'roaster': 'Sey',
        'name': 'Gichathaini',
      });
      final created = jsonDecode(await createRes.readAsString());
      beanId = created['id'];
    });

    test('POST /api/v1/beans/<beanId>/batches creates a batch', () async {
      final response = await sendPost('/api/v1/beans/$beanId/batches', {
        'roastLevel': 'light',
        'weight': 250.0,
      });
      expect(response.statusCode, 201);
      final body = jsonDecode(await response.readAsString());
      expect(body['beanId'], beanId);
      expect(body['roastLevel'], 'light');
      expect(body['weight'], 250.0);
    });

    test(
      'POST /api/v1/beans/<beanId>/batches preserves freeze fields',
      () async {
        final freezeDate = DateTime.utc(2026, 1, 2, 3, 4, 5, 6);
        final unfreezeDate = DateTime.utc(2026, 2, 3, 4, 5, 6, 7);
        final createResponse = await sendPost('/api/v1/beans/$beanId/batches', {
          'freezeDate': freezeDate.toIso8601String(),
          'unfreezeDate': unfreezeDate.toIso8601String(),
          'frozen': true,
        });
        final created = jsonDecode(await createResponse.readAsString());

        expect(DateTime.parse(created['freezeDate']), freezeDate);
        expect(DateTime.parse(created['unfreezeDate']), unfreezeDate);
        expect(created['frozen'], isTrue);

        final getResponse = await sendGet(
          '/api/v1/bean-batches/${created['id']}',
        );
        final fetched = jsonDecode(await getResponse.readAsString());
        expect(DateTime.parse(fetched['freezeDate']), freezeDate);
        expect(DateTime.parse(fetched['unfreezeDate']), unfreezeDate);
        expect(fetched['frozen'], isTrue);
      },
    );

    test('GET /api/v1/beans/<beanId>/batches returns batches', () async {
      await sendPost('/api/v1/beans/$beanId/batches', {
        'roastLevel': 'light',
        'weight': 250.0,
      });
      await sendPost('/api/v1/beans/$beanId/batches', {
        'roastLevel': 'medium',
        'weight': 500.0,
      });

      final response = await sendGet('/api/v1/beans/$beanId/batches');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, hasLength(2));
    });

    test(
      'GET /api/v1/bean-batches filters archived batches and parent beans',
      () async {
        final otherBeanResponse = await sendPost('/api/v1/beans', {
          'roaster': 'Tim Wendelboe',
          'name': 'Karogoto',
        });
        final otherBeanId = jsonDecode(
          await otherBeanResponse.readAsString(),
        )['id'];
        final first = jsonDecode(
          await (await sendPost('/api/v1/beans/$beanId/batches', {
            'roastLevel': 'light',
          })).readAsString(),
        );
        final second = jsonDecode(
          await (await sendPost('/api/v1/beans/$otherBeanId/batches', {
            'roastLevel': 'medium',
          })).readAsString(),
        );
        final archived = jsonDecode(
          await (await sendPost('/api/v1/beans/$otherBeanId/batches', {
            'roastLevel': 'dark',
          })).readAsString(),
        );
        await sendPut('/api/v1/bean-batches/${archived['id']}', {
          'archived': true,
        });
        await sendPut('/api/v1/beans/$otherBeanId', {'archived': true});

        final activeResponse = await sendGet('/api/v1/bean-batches');
        expect(activeResponse.statusCode, 200);
        final active = jsonDecode(await activeResponse.readAsString()) as List;
        expect(active.map((batch) => batch['id']).toSet(), {first['id']});

        final allResponse = await sendGet(
          '/api/v1/bean-batches?includeArchived=true',
        );
        final all = jsonDecode(await allResponse.readAsString()) as List;
        expect(all.map((batch) => batch['id']).toSet(), {
          first['id'],
          second['id'],
          archived['id'],
        });
      },
    );

    test('GET /api/v1/bean-batches supports conditional GET', () async {
      await sendPost('/api/v1/beans/$beanId/batches', {'roastLevel': 'light'});

      final response = await sendGet('/api/v1/bean-batches');
      final etag = response.headers['etag'];
      expect(etag, isNotNull);

      final cached = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/bean-batches'),
          headers: {'If-None-Match': etag!},
        ),
      );
      expect(cached.statusCode, 304);
      expect(cached.headers['etag'], etag);
      expect(await cached.readAsString(), isEmpty);
    });

    test('GET /api/v1/bean-batches/<id> returns a specific batch', () async {
      final createRes = await sendPost('/api/v1/beans/$beanId/batches', {
        'roastLevel': 'light',
        'weight': 250.0,
      });
      final created = jsonDecode(await createRes.readAsString());
      final batchId = created['id'];

      final response = await sendGet('/api/v1/bean-batches/$batchId');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['id'], batchId);
    });

    test('PUT /api/v1/bean-batches/<id> updates a batch', () async {
      final createRes = await sendPost('/api/v1/beans/$beanId/batches', {
        'roastLevel': 'light',
        'weight': 250.0,
      });
      final created = jsonDecode(await createRes.readAsString());
      final batchId = created['id'];

      final response = await sendPut('/api/v1/bean-batches/$batchId', {
        'roastLevel': 'medium',
        'notes': 'Very good batch',
      });
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString());
      expect(body['roastLevel'], 'medium');
      expect(body['notes'], 'Very good batch');
    });

    test(
      'PUT /api/v1/bean-batches/<id> preserves missing date fields',
      () async {
        final batch = BeanBatch.create(beanId: beanId, roastLevel: 'light');
        await storage.insertBatch(batch);
        final buyDate = DateTime.utc(2026, 3, 4, 5, 6, 7, 8);
        final openDate = DateTime.utc(2026, 4, 5, 6, 7, 8, 9);
        final bestBeforeDate = DateTime.utc(2026, 5, 6, 7, 8, 9, 10);
        final freezeDate = DateTime.utc(2026, 6, 7, 8, 9, 10, 11);
        final unfreezeDate = DateTime.utc(2026, 7, 8, 9, 10, 11, 12);
        final updateResponse =
            await sendPut('/api/v1/bean-batches/${batch.id}', {
              'harvestDate': '2025',
              'buyDate': buyDate.toIso8601String(),
              'openDate': openDate.toIso8601String(),
              'bestBeforeDate': bestBeforeDate.toIso8601String(),
              'freezeDate': freezeDate.toIso8601String(),
              'unfreezeDate': unfreezeDate.toIso8601String(),
            });
        final updated = jsonDecode(await updateResponse.readAsString());

        expect(updated['harvestDate'], '2025');
        expect(DateTime.parse(updated['buyDate']), buyDate);
        expect(DateTime.parse(updated['openDate']), openDate);
        expect(DateTime.parse(updated['bestBeforeDate']), bestBeforeDate);
        expect(DateTime.parse(updated['freezeDate']), freezeDate);
        expect(DateTime.parse(updated['unfreezeDate']), unfreezeDate);
        expect(updated['roastLevel'], 'light');

        final getResponse = await sendGet('/api/v1/bean-batches/${batch.id}');
        final fetched = jsonDecode(await getResponse.readAsString());
        expect(fetched['harvestDate'], '2025');
        expect(DateTime.parse(fetched['buyDate']), buyDate);
        expect(DateTime.parse(fetched['openDate']), openDate);
        expect(DateTime.parse(fetched['bestBeforeDate']), bestBeforeDate);
        expect(DateTime.parse(fetched['freezeDate']), freezeDate);
        expect(DateTime.parse(fetched['unfreezeDate']), unfreezeDate);
        expect(fetched['roastLevel'], 'light');

        final clearResponse = await sendPut(
          '/api/v1/bean-batches/${batch.id}',
          {'freezeDate': null},
        );
        final cleared = jsonDecode(await clearResponse.readAsString()) as Map;
        expect(cleared.containsKey('freezeDate'), isFalse);

        final rejected = await sendPut('/api/v1/bean-batches/${batch.id}', {
          'frozen': null,
        });
        expect(rejected.statusCode, 400);
      },
    );

    test(
      'PUT /api/v1/bean-batches/<id> rejects malformed numbers without mutation',
      () async {
        final createRes = await sendPost('/api/v1/beans/$beanId/batches', {
          'qualityScore': 87.5,
          'price': 18.5,
          'weight': 250.0,
        });
        final created = jsonDecode(await createRes.readAsString());
        final batchId = created['id'];
        const expected = {
          'qualityScore': 87.5,
          'price': 18.5,
          'weight': 250.0,
          'weightRemaining': 250.0,
        };

        for (final field in expected.keys) {
          final patch = {field: 'oops'};
          final response = await sendPut(
            '/api/v1/bean-batches/$batchId',
            patch,
          );
          expect(response.statusCode, 400, reason: '$patch');

          final stored = jsonDecode(
            await (await sendGet(
              '/api/v1/bean-batches/$batchId',
            )).readAsString(),
          );
          for (final entry in expected.entries) {
            expect(stored[entry.key], entry.value, reason: '$patch');
          }
        }

        final numericString = await sendPut('/api/v1/bean-batches/$batchId', {
          'price': '12.5',
        });
        expect(numericString.statusCode, 400);
        final stored = jsonDecode(
          await (await sendGet('/api/v1/bean-batches/$batchId')).readAsString(),
        );
        expect(stored['price'], 18.5);
      },
    );

    test('DELETE /api/v1/bean-batches/<id> deletes a batch', () async {
      final createRes = await sendPost('/api/v1/beans/$beanId/batches', {
        'roastLevel': 'light',
        'weight': 250.0,
      });
      final created = jsonDecode(await createRes.readAsString());
      final batchId = created['id'];

      final response = await sendDelete('/api/v1/bean-batches/$batchId');
      expect(response.statusCode, 200);

      final getRes = await sendGet('/api/v1/bean-batches/$batchId');
      expect(getRes.statusCode, 404);
    });
  });
}
