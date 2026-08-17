import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/storage/drift_profile_storage.dart';

Profile _profile(double tankTemperature) {
  return Profile(
    version: '2',
    title: 'Profile',
    author: 'Test',
    notes: '',
    beverageType: BeverageType.espresso,
    steps: [
      ProfileStepPressure(
        name: 'pour',
        transition: TransitionType.fast,
        volume: 100,
        seconds: 30,
        temperature: 93,
        sensor: TemperatureSensor.coffee,
        pressure: 9,
      ),
    ],
    tankTemperature: tankTemperature,
    targetVolumeCountStart: 0,
  );
}

void main() {
  late AppDatabase database;
  late DriftProfileStorageService storage;
  late domain.ProfileRecord original;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    storage = DriftProfileStorageService(database);
    original = domain.ProfileRecord.create(profile: _profile(93));
    await storage.store(original);
  });

  tearDown(() => database.close());

  test('atomically replaces an ID-changing profile', () async {
    final replacement = original.copyWith(profile: _profile(94));

    await storage.replace(original.id, replacement);

    expect(await storage.get(original.id), isNull);
    expect(await storage.get(replacement.id), replacement);
  });

  test('rolls back when storing the replacement fails', () async {
    final replacement = original.copyWith(
      profile: _profile(94),
      metadata: {'unsupported': Object()},
    );

    await expectLater(
      storage.replace(original.id, replacement),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );

    expect(await storage.get(original.id), original);
    expect(await storage.get(replacement.id), isNull);
  });

  test(
    'rejects a target ID collision without changing either profile',
    () async {
      final target = domain.ProfileRecord.create(profile: _profile(94));
      await storage.store(target);
      final replacement = original.copyWith(profile: target.profile);

      await expectLater(
        storage.replace(original.id, replacement),
        throwsArgumentError,
      );

      expect(await storage.get(original.id), original);
      expect(await storage.get(target.id), target);
    },
  );
}
