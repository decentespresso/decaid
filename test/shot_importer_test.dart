import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/util/shot_importer.dart';

/// Mock implementation of StorageService for testing
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
  Future<void> storeCurrentWorkflow(Workflow workflow) async {
    // Not needed for shot import tests
  }

  @override
  Future<Workflow?> loadCurrentWorkflow() async {
    // Not needed for shot import tests
    return null;
  }

  void reset() {
    storedShots.clear();
  }

  @override
  Future<void> deleteShot(String id) {
    // TODO: implement deleteShot
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

void main() {
  late MockStorageService mockStorage;
  late ShotImporter importer;

  setUp(() {
    mockStorage = MockStorageService();
    importer = ShotImporter(storage: mockStorage);
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
      expect(mockStorage.storedShots[0].workflow.name, 'Test Workflow');
    });

    test('should throw FormatException when JSON is not an object', () async {
      const invalidJson = '["not", "an", "object"]';

      expect(
        () => importer.importShotJson(invalidJson),
        throwsA(isA<FormatException>()),
      );
    });

    test('should throw FormatException when JSON is a primitive', () async {
      const invalidJson = '"just a string"';

      expect(
        () => importer.importShotJson(invalidJson),
        throwsA(isA<FormatException>()),
      );
    });

    test('should throw error when required fields are missing', () async {
      const invalidJson = '''
      {
        "id": "shot-123"
      }
      ''';

      expect(() => importer.importShotJson(invalidJson), throwsA(anything));
    });
  });

  group('ShotImporter - Multiple Shots Import', () {
    // Shot 1 uses legacy doseData (no context) to verify migration-on-read.
    // Shot 2 uses the modern context field.
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

    test('should throw FormatException when JSON is not an array', () async {
      const invalidJson = '''
      {
        "id": "shot-1",
        "timestamp": "2024-01-15T10:30:00.000Z"
      }
      ''';

      expect(
        () => importer.importShotsJson(invalidJson),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'should throw FormatException when array contains non-objects',
      () async {
        const invalidJson = '["string", 123, true]';

        expect(
          () => importer.importShotsJson(invalidJson),
          throwsA(isA<FormatException>()),
        );
      },
    );

    // Uses legacy doseData format to exercise migration-on-read path.
    test(
      'should throw FormatException when array contains mixed valid and invalid items',
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
          throwsA(isA<FormatException>()),
        );
      },
    );
  });

  group('ShotImporter - Edge Cases', () {
    test('should handle malformed JSON', () async {
      const malformedJson = '{ invalid json }';

      expect(
        () => importer.importShotJson(malformedJson),
        throwsA(isA<FormatException>()),
      );
    });

    // Uses legacy doseData format to exercise migration-on-read path.
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
            // Uses legacy doseData format to exercise migration-on-read path.
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
