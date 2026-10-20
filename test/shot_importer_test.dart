import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/util/shot_importer.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';

import 'helpers/shot_event_storage.dart';

class MockStorageService implements StorageService {
  final List<ShotRecord> storedShots = [];

  @override
  Future<void> storeShot(ShotRecord record) async {
    storedShots.add(record);
  }

  @override
  Future<List<String>> getShotIds() async {
    return storedShots.map((s) => s.id).toList();
  }

  @override
  Future<List<ShotRecord>> getAllShots() async {
    return storedShots;
  }

  @override
  Future<ShotRecord?> getShot(String id) async {
    try {
      return storedShots.firstWhere((s) => s.id == id);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> storeCurrentWorkflow(Workflow workflow) async {}

  @override
  Future<Workflow?> loadCurrentWorkflow() async {
    return null;
  }

  void reset() {
    storedShots.clear();
  }

  @override
  Future<void> deleteShot(String id) {
    throw UnimplementedError();
  }

  @override
  Future<void> updateShot(ShotRecord record) {
    throw UnimplementedError();
  }

  @override
  Future<List<ShotRecord>> getShotsPaginated({
    int limit = 20,
    int offset = 0,
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    bool ascending = false,
  }) async {
    return storedShots.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countShots({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    bool ascending = false,
  }) async {
    return storedShots.length;
  }

  @override
  Future<ShotRecord?> getLatestShot() async {
    if (storedShots.isEmpty) return null;
    return storedShots.last;
  }

  @override
  Future<ShotRecord?> getLatestShotMeta() => getLatestShot();

  @override
  Future<void> storeSteam(SteamRecord record) async {}
  @override
  Future<void> updateSteam(SteamRecord record) async {}
  @override
  Future<void> deleteSteam(String id) async {}
  @override
  Future<List<String>> getSteamIds() async => [];
  @override
  Future<List<SteamRecord>> getAllSteams() async => [];
  @override
  Future<SteamRecord?> getSteam(String id) async => null;
  @override
  Future<SteamRecord?> getLatestSteam() async => null;
  @override
  Future<SteamRecord?> getLatestSteamMeta() async => null;
}

class _FormatFailingStorage extends ShotEventStorage {
  final failure = const FormatException('Invalid persisted data');

  @override
  Future<void> storeShot(ShotRecord record) async {
    if (record.id == 'failed') throw failure;
    await super.storeShot(record);
  }
}

void main() {
  late MockStorageService mockStorage;
  late ShotImporter importer;
  late PersistenceController controller;
  late List<String> storedEvents;

  setUp(() {
    mockStorage = MockStorageService();
    storedEvents = [];
    controller = PersistenceController(storageService: mockStorage)
      ..onShotStored = storedEvents.add;
    importer = ShotImporter(controller: controller);
  });

  tearDown(() => controller.dispose());

  test(
    'single, empty and failed imports refresh only successful writes',
    () async {
      final storage = ShotEventStorage()..failedIds.add('failed');
      final persistence = PersistenceController(storageService: storage);
      addTearDown(persistence.dispose);
      final events = <String>[];
      persistence.onShotStored = events.add;
      var changes = 0;
      final subscription = persistence.shotsChanged.listen((_) => changes++);
      addTearDown(subscription.cancel);
      final importer = ShotImporter(controller: persistence);
      expect(await importer.importShotsJson('[]'), 0);
      await expectLater(
        importer.importShotsJson(
          jsonEncode([eventShot(id: 'failed').toJson()]),
        ),
        throwsStateError,
      );
      await expectLater(
        importer.importShotJson(jsonEncode(eventShot(id: 'failed').toJson())),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      expect(changes, 0);
      await importer.importShotJson(jsonEncode(eventShot(id: 'ok').toJson()));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['ok']);
      expect(changes, 1);
    },
  );

  test('bulk import keeps per-shot plugin events and one refresh', () async {
    var changes = 0;
    final subscription = controller.shotsChanged.listen((_) => changes++);
    addTearDown(subscription.cancel);
    final count = await importer.importShotsJson(
      jsonEncode([
        for (var i = 0; i < 3; i++) eventShot(id: 'shot-$i').toJson(),
      ]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(count, 3);
    expect(storedEvents, ['shot-0', 'shot-1', 'shot-2']);
    expect(changes, 1);
  });

  test(
    'failed import propagates and notifies only earlier successful inserts',
    () async {
      final storage = ShotEventStorage()..failedIds.add('failed');
      final persistence = PersistenceController(storageService: storage);
      addTearDown(persistence.dispose);
      final events = <String>[];
      persistence.onShotStored = events.add;
      var changes = 0;
      final subscription = persistence.shotsChanged.listen((_) => changes++);
      addTearDown(subscription.cancel);
      final importer = ShotImporter(controller: persistence);
      await expectLater(
        importer.importShotsJson(
          jsonEncode([
            eventShot(id: 'ok').toJson(),
            eventShot(id: 'failed').toJson(),
            eventShot(id: 'not reached').toJson(),
          ]),
        ),
        throwsStateError,
      );
      expect(events, ['ok']);
      expect(storage.shots.keys, ['ok']);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      await expectLater(
        importer.importShotJson(jsonEncode(eventShot(id: 'failed').toJson())),
        throwsStateError,
      );
      expect(events, ['ok']);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
    },
  );

  test(
    'storage FormatException stays unexpected after partial bulk import',
    () async {
      final storage = _FormatFailingStorage();
      final persistence = PersistenceController(storageService: storage);
      addTearDown(persistence.dispose);
      final importer = ShotImporter(controller: persistence);
      var changes = 0;
      final subscription = persistence.shotsChanged.listen((_) => changes++);
      addTearDown(subscription.cancel);

      await expectLater(
        importer.importShotsJson(
          jsonEncode([
            eventShot(id: 'ok').toJson(),
            eventShot(id: 'failed').toJson(),
            eventShot(id: 'not reached').toJson(),
          ]),
        ),
        throwsA(same(storage.failure)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(storage.shots.keys, ['ok']);
      expect(changes, 1);

      await expectLater(
        importer.importShotJson(jsonEncode(eventShot(id: 'failed').toJson())),
        throwsA(same(storage.failure)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
    },
  );

  test(
    'construction FormatException is user input and retains partial writes',
    () async {
      final invalid = eventShot(id: 'invalid').toJson()
        ..['timestamp'] = 'not a date';
      var changes = 0;
      final subscription = controller.shotsChanged.listen((_) => changes++);
      addTearDown(subscription.cancel);
      await expectLater(
        importer.importShotsJson(
          jsonEncode([eventShot(id: 'ok').toJson(), invalid]),
        ),
        throwsA(isA<UserFacingFormatException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(storedEvents, ['ok']);
      expect(changes, 1);
      await expectLater(
        importer.importShotJson(jsonEncode(invalid)),
        throwsA(isA<UserFacingFormatException>()),
      );
    },
  );

  test(
    'file entry point dispatches single objects, arrays and empty arrays',
    () async {
      expect(
        await importer.importJson(jsonEncode(eventShot(id: 'single').toJson())),
        1,
      );
      expect(
        await importer.importJson(
          jsonEncode([
            eventShot(id: 'bulk-1').toJson(),
            eventShot(id: 'bulk-2').toJson(),
          ]),
        ),
        2,
      );
      expect(await importer.importJson('[]'), 0);
      expect(storedEvents, ['single', 'bulk-1', 'bulk-2']);
    },
  );

  for (final input in ['null', '42', '"text"', '[null]', '{broken']) {
    test('file entry point classifies invalid input: $input', () async {
      await expectLater(
        importer.importJson(input),
        throwsA(isA<UserFacingFormatException>()),
      );
      expect(mockStorage.storedShots, isEmpty);
    });
  }

  for (final field in ['id', 'timestamp', 'measurements', 'workflow']) {
    test('invalid $field is a user-facing format failure', () async {
      final invalid = eventShot().toJson()..[field] = false;
      for (final input in [
        invalid,
        [invalid],
      ]) {
        await expectLater(
          importer.importJson(jsonEncode(input)),
          throwsA(isA<UserFacingFormatException>()),
        );
      }
      expect(mockStorage.storedShots, isEmpty);
    });
  }

  test('file entry point leaves storage FormatException unchanged', () async {
    final storage = _FormatFailingStorage();
    final persistence = PersistenceController(storageService: storage);
    addTearDown(persistence.dispose);
    final importer = ShotImporter(controller: persistence);
    for (final input in [
      eventShot(id: 'failed').toJson(),
      [eventShot(id: 'failed').toJson()],
    ]) {
      await expectLater(
        importer.importJson(jsonEncode(input)),
        throwsA(same(storage.failure)),
      );
    }
  });

  test('bulk malformed JSON is a user-facing format failure', () async {
    await expectLater(
      importer.importShotsJson('[invalid'),
      throwsA(isA<UserFacingFormatException>()),
    );
  });

  group('ShotImporter - Single Shot Import', () {
    test('should import a valid single shot JSON object', () async {
      const validShotJson = '''
      {
        "id": "shot-123",
        "timestamp": "2024-01-15T10:30:00.000Z",
        "measurements": [],
        "workflow": {
          "id": "workflow-1",
          "name": "Test Workflow",
          "description": "Test Description",
          "profile": {
            "title": "Test Profile",
            "author": "Test Author",
            "notes": "",
            "beverage_type": "espresso",
            "steps": [
            {
              "name": "pour",
              "pump": "pressure",
              "transition": "fast",
              "volume": 100,
              "seconds": 30,
              "temperature": 93,
              "sensor": "coffee",
              "pressure": 9
            }
          ],
            "tank_temperature": 0.0,
            "target_weight": 36.0,
            "target_volume": 0,
            "target_volume_count_start": 0,
            "legacy_profile_type": "",
            "type": "advanced",
            "lang": "en",
            "hidden": false,
            "reference_file": "",
            "changes_since_last_espresso": "",
            "version": "2"
          },
          "context": {
            "targetDoseWeight": 18.0,
            "targetYield": 36.0
          },
          "steamSettings": {
            "targetTemperature": 150,
            "duration": 50,
            "flow": 0.8
          },
          "hotWaterData": {
            "targetTemperature": 90,
            "duration": 15,
            "volume": 100,
            "flow": 4.0
          },
          "rinseData": {
            "targetTemperature": 90,
            "duration": 10,
            "flow": 6.0
          }
        }
      }
      ''';

      await importer.importShotJson(validShotJson);

      expect(mockStorage.storedShots.length, 1);
      expect(mockStorage.storedShots[0].id, 'shot-123');
      expect(storedEvents, ['shot-123']);
      expect(mockStorage.storedShots[0].workflow.name, 'Test Workflow');
    });

    test(
      'should throw UserFacingFormatException when JSON is not an object',
      () async {
        const invalidJson = '["not", "an", "object"]';

        expect(
          () => importer.importShotJson(invalidJson),
          throwsA(isA<UserFacingFormatException>()),
        );
      },
    );

    test(
      'should throw UserFacingFormatException when JSON is a primitive',
      () async {
        const invalidJson = '"just a string"';

        expect(
          () => importer.importShotJson(invalidJson),
          throwsA(isA<UserFacingFormatException>()),
        );
      },
    );

    test('should throw error when required fields are missing', () async {
      const invalidJson = '''
      {
        "id": "shot-123"
      }
      ''';

      expect(
        () => importer.importShotJson(invalidJson),
        throwsA(isA<UserFacingFormatException>()),
      );
    });

    test(
      'should name the missing fields and point to "Import from De1App" for a De1App history_v2 shot (keyed by clock, no id)',
      () async {
        const de1AppHistoryV2Shot = '''
        {
          "clock": 1700000000,
          "espresso_data": {}
        }
        ''';

        expect(
          () => importer.importShotJson(de1AppHistoryV2Shot),
          throwsA(
            isA<UserFacingFormatException>().having(
              (e) => e.message,
              'message',
              contains('Import from De1App'),
            ),
          ),
        );
      },
    );
  });

  group('ShotImporter - Multiple Shots Import', () {
    test('should import multiple valid shots from JSON array', () async {
      const validShotsJson = '''
      [
        {
          "id": "shot-1",
          "timestamp": "2024-01-15T10:30:00.000Z",
          "measurements": [],
          "workflow": {
            "id": "workflow-1",
            "name": "Workflow 1",
            "description": "Test",
            "profile": {
              "title": "Profile 1",
              "author": "Test",
              "notes": "",
              "beverage_type": "espresso",
              "steps": [
            {
              "name": "pour",
              "pump": "pressure",
              "transition": "fast",
              "volume": 100,
              "seconds": 30,
              "temperature": 93,
              "sensor": "coffee",
              "pressure": 9
            }
          ],
              "tank_temperature": 0.0,
              "target_weight": 36.0,
              "target_volume": 0,
              "target_volume_count_start": 0,
              "legacy_profile_type": "",
              "type": "advanced",
              "lang": "en",
              "hidden": false,
              "reference_file": "",
              "changes_since_last_espresso": "",
              "version": "2"
            },
            "doseData": {"doseIn": 18.0, "doseOut": 36.0},
            "steamSettings": {
              "targetTemperature": 150,
              "duration": 50,
              "flow": 0.8
            },
            "hotWaterData": {
              "targetTemperature": 90,
              "duration": 15,
              "volume": 100,
              "flow": 4.0
            },
            "rinseData": {
              "targetTemperature": 90,
              "duration": 10,
              "flow": 6.0
            }
          }
        },
        {
          "id": "shot-2",
          "timestamp": "2024-01-15T11:30:00.000Z",
          "measurements": [],
          "workflow": {
            "id": "workflow-2",
            "name": "Workflow 2",
            "description": "Test",
            "profile": {
              "title": "Profile 2",
              "author": "Test",
              "notes": "",
              "beverage_type": "espresso",
              "steps": [
            {
              "name": "pour",
              "pump": "pressure",
              "transition": "fast",
              "volume": 100,
              "seconds": 30,
              "temperature": 93,
              "sensor": "coffee",
              "pressure": 9
            }
          ],
              "tank_temperature": 0.0,
              "target_weight": 40.0,
              "target_volume": 0,
              "target_volume_count_start": 0,
              "legacy_profile_type": "",
              "type": "advanced",
              "lang": "en",
              "hidden": false,
              "reference_file": "",
              "changes_since_last_espresso": "",
              "version": "2"
            },
            "context": {"targetDoseWeight": 20.0, "targetYield": 40.0},
            "steamSettings": {
              "targetTemperature": 150,
              "duration": 50,
              "flow": 0.8
            },
            "hotWaterData": {
              "targetTemperature": 90,
              "duration": 15,
              "volume": 100,
              "flow": 4.0
            },
            "rinseData": {
              "targetTemperature": 90,
              "duration": 10,
              "flow": 6.0
            }
          }
        }
      ]
      ''';

      final count = await importer.importShotsJson(validShotsJson);

      expect(count, 2);
      expect(storedEvents, ['shot-1', 'shot-2']);
      expect(mockStorage.storedShots.length, 2);
      expect(mockStorage.storedShots[0].id, 'shot-1');
      expect(mockStorage.storedShots[1].id, 'shot-2');
      expect(mockStorage.storedShots[0].workflow.name, 'Workflow 1');
      expect(mockStorage.storedShots[1].workflow.name, 'Workflow 2');
    });

    test('should import empty array successfully', () async {
      const emptyArrayJson = '[]';

      final count = await importer.importShotsJson(emptyArrayJson);

      expect(count, 0);
      expect(mockStorage.storedShots.length, 0);
    });

    test(
      'should throw UserFacingFormatException when JSON is not an array',
      () async {
        const invalidJson = '''
      {
        "id": "shot-1",
        "timestamp": "2024-01-15T10:30:00.000Z"
      }
      ''';

        expect(
          () => importer.importShotsJson(invalidJson),
          throwsA(isA<UserFacingFormatException>()),
        );
      },
    );

    test(
      'should throw UserFacingFormatException when array contains non-objects',
      () async {
        const invalidJson = '["string", 123, true]';

        expect(
          () => importer.importShotsJson(invalidJson),
          throwsA(isA<UserFacingFormatException>()),
        );
      },
    );

    test(
      'should throw UserFacingFormatException when array contains mixed valid and invalid items',
      () async {
        const invalidJson = '''
      [
        {
          "id": "shot-1",
          "timestamp": "2024-01-15T10:30:00.000Z",
          "measurements": [],
          "workflow": {
            "id": "workflow-1",
            "name": "Workflow 1",
            "description": "Test",
            "profile": {
              "title": "Profile 1",
              "author": "Test",
              "notes": "",
              "beverage_type": "espresso",
              "steps": [
            {
              "name": "pour",
              "pump": "pressure",
              "transition": "fast",
              "volume": 100,
              "seconds": 30,
              "temperature": 93,
              "sensor": "coffee",
              "pressure": 9
            }
          ],
              "tank_temperature": 0.0,
              "target_weight": 36.0,
              "target_volume": 0,
              "target_volume_count_start": 0,
              "legacy_profile_type": "",
              "type": "advanced",
              "lang": "en",
              "hidden": false,
              "reference_file": "",
              "changes_since_last_espresso": "",
              "version": "2"
            },
            "doseData": {"doseIn": 18.0, "doseOut": 36.0},
            "steamSettings": {
              "targetTemperature": 150,
              "duration": 50,
              "flow": 0.8
            },
            "hotWaterData": {
              "targetTemperature": 90,
              "duration": 15,
              "volume": 100,
              "flow": 4.0
            },
            "rinseData": {
              "targetTemperature": 90,
              "duration": 10,
              "flow": 6.0
            }
          }
        },
        "invalid item"
      ]
      ''';

        expect(
          () => importer.importShotsJson(invalidJson),
          throwsA(isA<UserFacingFormatException>()),
        );
      },
    );
  });

  group('ShotImporter - Edge Cases', () {
    test('should handle malformed JSON', () async {
      const malformedJson = '{ invalid json }';

      expect(
        () => importer.importShotJson(malformedJson),
        throwsA(isA<UserFacingFormatException>()),
      );
    });

    test('should handle null values in optional fields', () async {
      const jsonWithNulls = '''
      {
        "id": "shot-null-test",
        "timestamp": "2024-01-15T10:30:00.000Z",
        "measurements": [],
        "workflow": {
          "id": "workflow-1",
          "name": "Test Workflow",
          "description": "",
          "profile": {
            "title": "Test Profile",
            "author": "Test Author",
            "notes": "",
            "beverage_type": "espresso",
            "steps": [
            {
              "name": "pour",
              "pump": "pressure",
              "transition": "fast",
              "volume": 100,
              "seconds": 30,
              "temperature": 93,
              "sensor": "coffee",
              "pressure": 9
            }
          ],
            "tank_temperature": 0.0,
            "target_weight": 36.0,
            "target_volume": 0,
            "target_volume_count_start": 0,
            "legacy_profile_type": "",
            "type": "advanced",
            "lang": "en",
            "hidden": false,
            "reference_file": "",
            "changes_since_last_espresso": "",
            "version": "2"
          },
          "doseData": {"doseIn": 18.0, "doseOut": 36.0},
          "grinderData": null,
          "coffeeData": null,
          "steamSettings": {
            "targetTemperature": 150,
            "duration": 50,
            "flow": 0.8
          },
          "hotWaterData": {
            "targetTemperature": 90,
            "duration": 15,
            "volume": 100,
            "flow": 4.0
          },
          "rinseData": {
            "targetTemperature": 90,
            "duration": 10,
            "flow": 6.0
          }
        }
      }
      ''';

      await importer.importShotJson(jsonWithNulls);

      expect(mockStorage.storedShots.length, 1);
      expect(mockStorage.storedShots[0].id, 'shot-null-test');
    });

    test('should return correct count for large batch import', () async {
      final largeArray = List.generate(
        100,
        (i) => {
          "id": "shot-$i",
          "timestamp": "2024-01-15T10:30:00.000Z",
          "measurements": [],
          "workflow": {
            "id": "workflow-$i",
            "name": "Workflow $i",
            "description": "Test",
            "profile": {
              "title": "Profile $i",
              "author": "Test",
              "notes": "",
              "beverage_type": "espresso",
              "steps": [
                {
                  "name": "pour",
                  "pump": "pressure",
                  "transition": "fast",
                  "volume": 100,
                  "seconds": 30,
                  "temperature": 93,
                  "sensor": "coffee",
                  "pressure": 9,
                },
              ],
              "tank_temperature": 0.0,
              "target_weight": 36.0,
              "target_volume": 0,
              "target_volume_count_start": 0,
              "legacy_profile_type": "",
              "type": "advanced",
              "lang": "en",
              "hidden": false,
              "reference_file": "",
              "changes_since_last_espresso": "",
              "version": "2",
            },
            "doseData": {"doseIn": 18.0, "doseOut": 36.0},
            "steamSettings": {
              "targetTemperature": 150,
              "duration": 50,
              "flow": 0.8,
            },
            "hotWaterData": {
              "targetTemperature": 90,
              "duration": 15,
              "volume": 100,
              "flow": 4.0,
            },
            "rinseData": {"targetTemperature": 90, "duration": 10, "flow": 6.0},
          },
        },
      );

      final largeJson = jsonEncode(largeArray);
      final count = await importer.importShotsJson(largeJson);

      expect(count, 100);
      expect(mockStorage.storedShots.length, 100);
    });
  });
}
