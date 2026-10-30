import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/bean.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/services/database/database.dart'
    hide Bean, ShotRecord;
import 'package:reaprime/src/services/storage/drift_bean_storage.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:reaprime/src/services/webserver/shots_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

void main() {
  late AppDatabase db;
  late DriftBeanStorageService beanStorage;
  late PersistenceController persistence;
  late Handler handler;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    beanStorage = DriftBeanStorageService(db);
    persistence = PersistenceController(
      storageService: DriftStorageService(db),
    );
    final shotsHandler = ShotsHandler(
      controller: persistence,
      beanStorage: beanStorage,
    );
    final app = Router().plus;
    shotsHandler.addRoutes(app);
    handler = app.call;
  });

  tearDown(() async {
    persistence.dispose();
    await db.close();
  });

  Future<Response> sendGet(String path) async =>
      handler(Request('GET', Uri.parse('http://localhost$path')));

  Future<Response> sendPut(String id, Map<String, dynamic> patch) async =>
      handler(
        Request(
          'PUT',
          Uri.parse('http://localhost/api/v1/shots/$id'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(patch),
        ),
      );

  Future<Map<String, dynamic>> decode(Response response) async =>
      jsonDecode(await response.readAsString()) as Map<String, dynamic>;

  Future<void> persistAnnotatedShot({String id = 'annotated'}) =>
      persistence.persistShot(
        makeShot(
          id: id,
          annotations: const ShotAnnotations(
            espressoNotes: 'old notes',
            extras: {'favorite': false, 'origin': 'existing'},
          ),
        ),
      );

  Future<(Map<String, dynamic>, Map<String, dynamic>)> putAndGet(
    String id,
    Map<String, dynamic> patch,
  ) async {
    final putResponse = await sendPut(id, patch);
    expect(putResponse.statusCode, 200);
    final putJson = await decode(putResponse);

    final getResponse = await sendGet('/api/v1/shots/$id');
    expect(getResponse.statusCode, 200);
    return (putJson, await decode(getResponse));
  }

  group('ShotsHandler', () {
    test(
      'PUT emits exactly one update with the submitted patch and current metadata',
      () async {
        await persistAnnotatedShot();
        final events = <Map<String, dynamic>>[];
        persistence.onShotUpdated = (shot, patch) => events.add({
          'id': shot.id,
          'shot': shot.toJsonWithoutMeasurements(),
          'patch': patch,
        });
        final patch = <String, dynamic>{
          'shotNotes': 'new legacy notes',
          'annotations': {'enjoyment': 8.5},
        };
        final response = await sendPut('annotated', patch);
        expect(response.statusCode, 200);
        final stored = await persistence.storageService.getShot('annotated');
        expect(events, [
          {
            'id': 'annotated',
            'shot': stored!.toJsonWithoutMeasurements(),
            'patch': patch,
          },
        ]);
        expect(events.single['shot'].containsKey('measurements'), isFalse);
        expect(
          events.single['shot']['annotations']['espressoNotes'],
          'new legacy notes',
        );
        expect((await sendPut('missing', patch)).statusCode, 404);
        expect(events, hasLength(1));
      },
    );

    test('GET /api/v1/shots filters by beanId across all batches', () async {
      final bean = Bean.create(roaster: 'Old roaster', name: 'Old name');
      final otherBean = Bean.create(roaster: 'Other', name: 'Coffee');
      await beanStorage.insertBean(bean);
      await beanStorage.insertBean(otherBean);
      final firstBatch = BeanBatch.create(beanId: bean.id);
      final secondBatch = BeanBatch.create(beanId: bean.id);
      final otherBatch = BeanBatch.create(beanId: otherBean.id);
      await beanStorage.insertBatch(firstBatch);
      await beanStorage.insertBatch(secondBatch);
      await beanStorage.insertBatch(otherBatch);

      await persistence.persistShot(
        makeShot(
          id: 's1',
          timestamp: DateTime.utc(2026, 1, 1, 10),
          beanBatchId: firstBatch.id,
          coffeeName: 'Old name',
          coffeeRoaster: 'Old roaster',
        ),
      );
      await persistence.persistShot(
        makeShot(
          id: 's2',
          timestamp: DateTime.utc(2026, 1, 2, 10),
          beanBatchId: secondBatch.id,
          coffeeName: 'Renamed coffee',
          coffeeRoaster: 'Renamed roaster',
        ),
      );
      await persistence.persistShot(
        makeShot(
          id: 's3',
          timestamp: DateTime.utc(2026, 1, 3, 10),
          beanBatchId: otherBatch.id,
          coffeeName: 'Other',
          coffeeRoaster: 'Coffee',
        ),
      );
      await beanStorage.updateBean(
        bean.copyWith(roaster: 'Renamed roaster', name: 'Renamed coffee'),
      );

      final response = await sendGet('/api/v1/shots?beanId=${bean.id}');
      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['total'], 2);
      expect((body['items'] as List).map((item) => item['id']).toList(), [
        's2',
        's1',
      ]);
    });

    test('GET /api/v1/shots filters by minEnjoyment', () async {
      await persistence.persistShot(
        makeShot(
          id: 'low',
          timestamp: DateTime.utc(2026, 1, 1, 10),
          annotations: const ShotAnnotations(enjoyment: 4),
        ),
      );
      await persistence.persistShot(
        makeShot(
          id: 'high',
          timestamp: DateTime.utc(2026, 1, 2, 10),
          annotations: const ShotAnnotations(enjoyment: 8),
        ),
      );
      await persistence.persistShot(
        makeShot(id: 'unrated', timestamp: DateTime.utc(2026, 1, 3, 10)),
      );

      final response = await sendGet('/api/v1/shots?minEnjoyment=6');
      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['total'], 1);
      expect((body['items'] as List).map((item) => item['id']).toList(), [
        'high',
      ]);
    });

    test('GET /api/v1/shots accepts the minEnjoyment range bounds', () async {
      await persistence.persistShot(
        makeShot(
          id: 'zero',
          timestamp: DateTime.utc(2026, 1, 1, 10),
          annotations: const ShotAnnotations(enjoyment: 0),
        ),
      );
      await persistence.persistShot(
        makeShot(
          id: 'ten',
          timestamp: DateTime.utc(2026, 1, 2, 10),
          annotations: const ShotAnnotations(enjoyment: 10),
        ),
      );

      final atZero = await decode(
        await sendGet('/api/v1/shots?minEnjoyment=0'),
      );
      expect((atZero['items'] as List).map((item) => item['id']).toList(), [
        'ten',
        'zero',
      ]);
      expect(atZero['total'], 2);

      final atTen = await decode(
        await sendGet('/api/v1/shots?minEnjoyment=10'),
      );
      expect((atTen['items'] as List).map((item) => item['id']).toList(), [
        'ten',
      ]);
      expect(atTen['total'], 1);
    });

    test('GET /api/v1/shots rejects an out-of-contract minEnjoyment', () async {
      for (final value in ['great', '-1', '11', 'NaN', 'Infinity']) {
        final response = await sendGet('/api/v1/shots?minEnjoyment=$value');
        expect(response.statusCode, 400, reason: 'minEnjoyment=$value');
      }
    });

    test('GET /api/v1/shots rejects ids combined with a filter', () async {
      await persistence.persistShot(
        makeShot(
          id: 'shot-a',
          annotations: const ShotAnnotations(enjoyment: 2),
        ),
      );
      await persistence.persistShot(
        makeShot(
          id: 'shot-b',
          annotations: const ShotAnnotations(enjoyment: 9),
        ),
      );

      final response = await sendGet('/api/v1/shots?ids=shot-a&minEnjoyment=6');
      expect(response.statusCode, 400);

      final idsOnly = await sendGet('/api/v1/shots?ids=shot-a');
      expect(idsOnly.statusCode, 200);
      final body = jsonDecode(await idsOnly.readAsString()) as List;
      expect(body.map((item) => item['id']).toList(), ['shot-a']);
    });

    test('GET /api/v1/shots total matches the filtered items', () async {
      for (var i = 0; i < 5; i++) {
        await persistence.persistShot(
          makeShot(
            id: 'shot-$i',
            timestamp: DateTime.utc(2026, 1, 1 + i, 10),
            coffeeName: i.isEven ? 'Match' : 'Other',
            annotations: ShotAnnotations(enjoyment: i.toDouble() + 5),
          ),
        );
      }

      final page = await decode(
        await sendGet('/api/v1/shots?search=Match&minEnjoyment=6&limit=1'),
      );
      expect(page['total'], 2);
      expect((page['items'] as List), hasLength(1));

      final all = await decode(
        await sendGet('/api/v1/shots?search=Match&minEnjoyment=6&limit=100'),
      );
      expect((all['items'] as List).map((item) => item['id']).toList(), [
        'shot-4',
        'shot-2',
      ]);
      expect(all['total'], (all['items'] as List).length);
    });

    test(
      'GET /api/v1/shots with unknown beanId returns an empty page',
      () async {
        await persistence.persistShot(
          makeShot(
            id: 's1',
            beanBatchId: 'batch-a',
            coffeeName: 'Name',
            coffeeRoaster: 'Roaster',
          ),
        );

        final response = await sendGet('/api/v1/shots?beanId=missing');
        expect(response.statusCode, 200);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['total'], 0);
        expect(body['items'], isEmpty);
      },
    );

    test(
      'PUT clears the grinder burrs snapshot with an explicit null',
      () async {
        await persistence.persistShot(
          makeShot(id: 'burrs', grinderModel: 'EG1', grinderBurrs: 'Core'),
        );

        final (putJson, getJson) = await putAndGet('burrs', {
          'workflow': {
            'context': {
              'grinderModel': 'EG1 (Lab Sweet)',
              'grinderBurrs': null,
            },
          },
        });

        for (final json in [putJson, getJson]) {
          final context =
              (json['workflow'] as Map)['context'] as Map<String, dynamic>;
          expect(context['grinderModel'], 'EG1 (Lab Sweet)');
          expect(context.containsKey('grinderBurrs'), isFalse);
        }
      },
    );

    test('legacy shotNotes updates canonical notes and persists', () async {
      await persistAnnotatedShot();

      final (putJson, getJson) = await putAndGet('annotated', {
        'shotNotes': 'new legacy notes',
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations']['espressoNotes'], 'new legacy notes');
        expect(json['shotNotes'], 'new legacy notes');
      }
    });

    test('legacy metadata deep-merges canonical extras and persists', () async {
      await persistAnnotatedShot();

      final (putJson, getJson) = await putAndGet('annotated', {
        'metadata': {'favorite': true},
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations']['extras'], {
          'favorite': true,
          'origin': 'existing',
        });
        expect(json['metadata'], json['annotations']['extras']);
      }
    });

    test('canonical annotation fields win over legacy aliases', () async {
      await persistAnnotatedShot();

      final (putJson, getJson) = await putAndGet('annotated', {
        'annotations': {
          'espressoNotes': 'canonical',
          'extras': {'favorite': true},
        },
        'shotNotes': 'legacy',
        'metadata': {'favorite': false, 'legacy': true},
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations']['espressoNotes'], 'canonical');
        expect(json['shotNotes'], 'canonical');
        expect(json['annotations']['extras'], {
          'favorite': true,
          'origin': 'existing',
        });
        expect(json['metadata'], json['annotations']['extras']);
      }
    });

    test('canonical null clears notes without changing extras', () async {
      await persistAnnotatedShot();

      final (putJson, getJson) = await putAndGet('annotated', {
        'annotations': {'espressoNotes': null},
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations']['espressoNotes'], '');
        expect(json['shotNotes'], '');
        expect(json['annotations']['extras'], {
          'favorite': false,
          'origin': 'existing',
        });
      }
    });

    test('canonical null clears extras without changing notes', () async {
      await persistAnnotatedShot();

      final (putJson, getJson) = await putAndGet('annotated', {
        'annotations': {'extras': null},
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations'].containsKey('extras'), isFalse);
        expect(json.containsKey('metadata'), isFalse);
        expect(json['annotations']['espressoNotes'], 'old notes');
      }
    });

    test('annotations null clears all annotations and aliases', () async {
      await persistAnnotatedShot();

      final (putJson, getJson) = await putAndGet('annotated', {
        'annotations': null,
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations'], {'espressoNotes': ''});
        expect(json['shotNotes'], '');
        expect(json.containsKey('metadata'), isFalse);
      }
    });

    test('annotations null wins over conflicting legacy aliases', () async {
      await persistAnnotatedShot();

      final (putJson, getJson) = await putAndGet('annotated', {
        'annotations': null,
        'shotNotes': 'must be ignored',
        'metadata': {'must': 'be ignored'},
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations'], {'espressoNotes': ''});
        expect(json['shotNotes'], '');
        expect(json.containsKey('metadata'), isFalse);
      }
    });

    test(
      'a cleared note stays cleared over a pre-shot workflow note',
      () async {
        await persistence.persistShot(
          makeShot(
            id: 'preshot',
            annotations: const ShotAnnotations(espressoNotes: 'After shot'),
            contextExtras: const {'note': 'Before shot'},
          ),
        );

        final (putJson, getJson) = await putAndGet('preshot', {
          'annotations': {'espressoNotes': null},
        });

        for (final json in [putJson, getJson]) {
          expect(json['annotations']['espressoNotes'], '');
          expect(json['shotNotes'], '');
          expect(json['workflow']['context']['extras'], {
            'note': 'Before shot',
          });
        }
      },
    );

    test(
      'clearing a shot that never had a note stores an empty note',
      () async {
        await persistence.persistShot(makeShot(id: 'plain'));

        final (putJson, getJson) = await putAndGet('plain', {
          'annotations': {'espressoNotes': null},
        });

        for (final json in [putJson, getJson]) {
          expect(json['annotations']['espressoNotes'], '');
          expect(json['shotNotes'], '');
        }
      },
    );

    test(
      'annotations null ignores a legacy shotNotes in the same request',
      () async {
        await persistAnnotatedShot();

        final (putJson, getJson) = await putAndGet('annotated', {
          'annotations': null,
          'shotNotes': 'ignored',
        });

        for (final json in [putJson, getJson]) {
          expect(json['annotations'], {'espressoNotes': ''});
          expect(json['shotNotes'], '');
        }
      },
    );

    test('an unrelated edit keeps a cleared note empty', () async {
      await persistAnnotatedShot();
      await putAndGet('annotated', {
        'annotations': {'espressoNotes': null},
      });

      final (putJson, getJson) = await putAndGet('annotated', {
        'annotations': {'enjoyment': 7},
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations']['espressoNotes'], '');
        expect(json['annotations']['enjoyment'], 7);
      }
    });

    test('legacy nulls clear canonical values and aliases', () async {
      await persistAnnotatedShot();

      final (notesPut, notesGet) = await putAndGet('annotated', {
        'shotNotes': null,
      });
      for (final json in [notesPut, notesGet]) {
        expect(json['annotations']['espressoNotes'], '');
        expect(json['shotNotes'], '');
        expect(json['annotations']['extras'], isNotNull);
      }

      final (metadataPut, metadataGet) = await putAndGet('annotated', {
        'metadata': null,
      });
      for (final json in [metadataPut, metadataGet]) {
        expect(json['annotations'].containsKey('extras'), isFalse);
        expect(json.containsKey('metadata'), isFalse);
      }
    });

    test('unrelated partial update preserves annotations', () async {
      await persistAnnotatedShot();

      final (putJson, getJson) = await putAndGet('annotated', {
        'stopReason': 'apiStop',
      });

      for (final json in [putJson, getJson]) {
        expect(json['stopReason'], 'apiStop');
        expect(json['annotations'], {
          'espressoNotes': 'old notes',
          'extras': {'favorite': false, 'origin': 'existing'},
        });
        expect(json['shotNotes'], 'old notes');
        expect(json['metadata'], json['annotations']['extras']);
      }
    });

    test('decent upload rejection marker preserves updatedAt', () async {
      await persistAnnotatedShot();

      final before = await decode(await sendGet('/api/v1/shots/annotated'));

      final (putJson, getJson) = await putAndGet('annotated', {
        'annotations': {
          'extras': {
            'decent_upload_rejected': {'status': 422, 'timestamp': 1767230000},
          },
        },
      });

      for (final json in [putJson, getJson]) {
        expect(
          DateTime.parse(json['updatedAt']),
          DateTime.parse(before['updatedAt'] as String),
        );
      }
    });

    test('non-bookkeeping extras change advances updatedAt', () async {
      await persistAnnotatedShot();

      final before = await decode(await sendGet('/api/v1/shots/annotated'));

      final (putJson, getJson) = await putAndGet('annotated', {
        'annotations': {
          'extras': {'favorite': true},
        },
      });

      for (final json in [putJson, getJson]) {
        expect(
          DateTime.parse(
            json['updatedAt'],
          ).isAfter(DateTime.parse(before['updatedAt'] as String)),
          isTrue,
        );
      }
    });

    test('PUT with measurements is rejected', () async {
      await persistAnnotatedShot();

      final response = await sendPut('annotated', {'measurements': []});
      expect(response.statusCode, 400);
      expect((await decode(response))['error'], contains('measurements'));
    });

    test('PUT with an enjoyment above the canonical max is rejected', () async {
      await persistAnnotatedShot();

      final response = await sendPut('annotated', {
        'annotations': {'enjoyment': 80},
      });
      expect(response.statusCode, 400);
      expect((await decode(response))['error'], contains('enjoyment'));

      final stored = await decode(await sendGet('/api/v1/shots/annotated'));
      expect((stored['annotations'] as Map)['enjoyment'], isNull);
    });

    test('PUT with a negative enjoyment is rejected', () async {
      await persistAnnotatedShot();

      final response = await sendPut('annotated', {
        'annotations': {'enjoyment': -1},
      });
      expect(response.statusCode, 400);
    });

    test('PUT with a non-numeric enjoyment is rejected', () async {
      await persistAnnotatedShot();

      final response = await sendPut('annotated', {
        'annotations': {'enjoyment': 'great'},
      });
      expect(response.statusCode, 400);
    });

    test('PUT accepts an enjoyment inside the canonical range', () async {
      await persistAnnotatedShot();

      final (_, getJson) = await putAndGet('annotated', {
        'annotations': {'enjoyment': 8.5},
      });
      expect((getJson['annotations'] as Map)['enjoyment'], 8.5);
    });

    test('PUT accepts a null enjoyment to clear the rating', () async {
      await persistAnnotatedShot();
      await putAndGet('annotated', {
        'annotations': {'enjoyment': 3},
      });

      final (_, getJson) = await putAndGet('annotated', {
        'annotations': {'enjoyment': null},
      });
      expect((getJson['annotations'] as Map)['enjoyment'], isNull);
    });

    test('content patch advances updatedAt', () async {
      await persistAnnotatedShot();

      final before = await decode(await sendGet('/api/v1/shots/annotated'));

      final (putJson, getJson) = await putAndGet('annotated', {
        'annotations': {'espressoNotes': 'edited'},
      });

      for (final json in [putJson, getJson]) {
        expect(json['updatedAt'], endsWith('Z'));
        expect(
          DateTime.parse(
            json['updatedAt'],
          ).isAfter(DateTime.parse(before['updatedAt'] as String)),
          isTrue,
        );
      }
    });

    test('first uploaded_to_decent write on a shot with no annotations '
        'preserves updatedAt', () async {
      await persistence.persistShot(makeShot(id: 'clean'));
      final before = await decode(await sendGet('/api/v1/shots/clean'));

      final (putJson, getJson) = await putAndGet('clean', {
        'annotations': {
          'extras': {'uploaded_to_decent': 1767230000},
        },
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations']['extras'], {
          'uploaded_to_decent': 1767230000,
        });
        expect(
          DateTime.parse(json['updatedAt'] as String),
          DateTime.parse(before['updatedAt'] as String),
        );
      }
    });

    test('first bookkeeping write on annotations with no extras '
        'preserves updatedAt', () async {
      await persistence.persistShot(
        makeShot(
          id: 'notes-only',
          annotations: const ShotAnnotations(espressoNotes: 'hi'),
        ),
      );
      final before = await decode(await sendGet('/api/v1/shots/notes-only'));

      final (putJson, getJson) = await putAndGet('notes-only', {
        'annotations': {
          'extras': {'visualizerId': 'viz-1'},
        },
      });

      for (final json in [putJson, getJson]) {
        expect(json['annotations']['extras'], {'visualizerId': 'viz-1'});
        expect(
          DateTime.parse(json['updatedAt'] as String),
          DateTime.parse(before['updatedAt'] as String),
        );
      }
    });

    test(
      'changing an existing bookkeeping value preserves updatedAt',
      () async {
        await persistAnnotatedShot();
        await putAndGet('annotated', {
          'annotations': {
            'extras': {'uploaded_to_decent': 100},
          },
        });
        final before = await decode(await sendGet('/api/v1/shots/annotated'));

        final (putJson, getJson) = await putAndGet('annotated', {
          'annotations': {
            'extras': {'uploaded_to_decent': 200},
          },
        });

        for (final json in [putJson, getJson]) {
          expect(json['annotations']['extras']['uploaded_to_decent'], 200);
          expect(json['annotations']['extras']['favorite'], false);
          expect(
            DateTime.parse(json['updatedAt'] as String),
            DateTime.parse(before['updatedAt'] as String),
          );
        }
      },
    );

    test(
      'visualizerId-only write on annotated shot preserves updatedAt',
      () async {
        await persistAnnotatedShot();
        final before = await decode(await sendGet('/api/v1/shots/annotated'));

        final (putJson, getJson) = await putAndGet('annotated', {
          'annotations': {
            'extras': {'visualizerId': 'viz-9'},
          },
        });

        for (final json in [putJson, getJson]) {
          expect(json['annotations']['extras']['visualizerId'], 'viz-9');
          expect(
            DateTime.parse(json['updatedAt'] as String),
            DateTime.parse(before['updatedAt'] as String),
          );
        }
      },
    );

    test(
      'mixed bookkeeping plus meaningful extra advances updatedAt',
      () async {
        await persistAnnotatedShot();
        final before = await decode(await sendGet('/api/v1/shots/annotated'));

        final (putJson, getJson) = await putAndGet('annotated', {
          'annotations': {
            'extras': {'uploaded_to_decent': 1, 'favorite': true},
          },
        });

        for (final json in [putJson, getJson]) {
          expect(json['annotations']['extras']['uploaded_to_decent'], 1);
          expect(json['annotations']['extras']['favorite'], true);
          expect(
            DateTime.parse(
              json['updatedAt'],
            ).isAfter(DateTime.parse(before['updatedAt'] as String)),
            isTrue,
          );
        }
      },
    );

    test(
      'PUT with createdAt or updatedAt is rejected and leaves values intact',
      () async {
        await persistAnnotatedShot();
        final before = await decode(await sendGet('/api/v1/shots/annotated'));

        for (final field in ['createdAt', 'updatedAt']) {
          final response = await sendPut('annotated', {
            field: '2000-01-01T00:00:00Z',
          });
          expect(response.statusCode, 400);
          expect((await decode(response))['error'], contains(field));
        }

        final after = await decode(await sendGet('/api/v1/shots/annotated'));
        expect(after['createdAt'], before['createdAt']);
        expect(after['updatedAt'], before['updatedAt']);
      },
    );
  });
}

ShotRecord makeShot({
  required String id,
  DateTime? timestamp,
  String? beanBatchId,
  String? coffeeName,
  String? coffeeRoaster,
  String? grinderModel,
  String? grinderBurrs,
  ShotAnnotations? annotations,
  Map<String, dynamic>? contextExtras,
}) {
  final workflow = WorkflowController().currentWorkflow.copyWith(
    context: WorkflowContext(
      beanBatchId: beanBatchId,
      coffeeName: coffeeName,
      coffeeRoaster: coffeeRoaster,
      grinderModel: grinderModel,
      grinderBurrs: grinderBurrs,
      extras: contextExtras,
    ),
  );
  return ShotRecord(
    id: id,
    timestamp: timestamp ?? DateTime.utc(2026, 1, 1, 10),
    measurements: const [],
    workflow: workflow,
    annotations: annotations,
  );
}
