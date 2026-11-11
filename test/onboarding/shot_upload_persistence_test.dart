import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

base class _MemoryAsyncPreferences extends SharedPreferencesAsyncPlatform {
  final values = <String, Object>{};
  bool failWrites = false;

  void _checkWrite() {
    if (failWrites) throw StateError('write failed');
  }

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    _checkWrite();
    values[key] = value;
  }

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) async {
    _checkWrite();
    values[key] = value;
  }

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) async {
    _checkWrite();
    values[key] = value;
  }

  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) async {
    _checkWrite();
    values[key] = value;
  }

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) async {
    _checkWrite();
    values[key] = value;
  }

  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async => values[key] as String?;

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) async =>
      values[key] as bool?;

  @override
  Future<double?> getDouble(
    String key,
    SharedPreferencesOptions options,
  ) async => values[key] as double?;

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) async =>
      values[key] as int?;

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) async => values[key] as List<String>?;

  @override
  Future<void> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    _checkWrite();
    values.clear();
  }

  @override
  Future<Map<String, Object>> getPreferences(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async => Map<String, Object>.of(values);

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async => values.keys.toSet();
}

void main() {
  late _MemoryAsyncPreferences platform;

  setUp(() {
    platform = _MemoryAsyncPreferences();
    SharedPreferencesAsyncPlatform.instance = platform;
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
    SharedPreferences.resetStatic();
  });

  test(
    'persists a decision and completion atomically across reconstruction',
    () async {
      final first = SettingsController(SharedPreferencesSettingsService());
      await first.loadSettings();
      await first.setShotUploadDecision(true);

      final raw =
          platform.values[SettingsKeys.shotUploadDecision.name] as String;
      expect(jsonDecode(raw), {'answer': true, 'pending': true, 'seen': true});

      final restarted = SettingsController(SharedPreferencesSettingsService());
      await restarted.loadSettings();
      expect(restarted.shotUploadStepSeen, isTrue);
      expect(restarted.shotUploadPendingDecision, isTrue);

      await restarted.clearShotUploadPendingDecision();
      final afterClear = SettingsController(SharedPreferencesSettingsService());
      await afterClear.loadSettings();
      expect(afterClear.shotUploadStepSeen, isTrue);
      expect(afterClear.shotUploadPendingDecision, isNull);
      expect(
        jsonDecode(
          platform.values[SettingsKeys.shotUploadDecision.name] as String,
        ),
        {'answer': true, 'pending': false, 'seen': true},
      );
    },
  );

  test('pending false is distinct from an absent pending record', () async {
    final service = SharedPreferencesSettingsService();
    await service.setShotUploadDecision(false);
    await service.clearShotUploadPendingDecision();
    expect(await service.shotUploadPendingDecision(), isNull);
    expect(await service.shotUploadStepSeen(), isTrue);

    await platform.setString(
      SettingsKeys.shotUploadDecision.name,
      jsonEncode({'answer': false, 'pending': true, 'seen': true}),
      const SharedPreferencesOptions(),
    );
    expect(await service.shotUploadPendingDecision(), isFalse);
  });

  test(
    'a failed decision write leaves a reconstructed controller unchanged',
    () async {
      final service = SharedPreferencesSettingsService();
      final controller = SettingsController(service);
      await controller.loadSettings();
      platform.failWrites = true;

      await expectLater(
        controller.setShotUploadDecision(true),
        throwsA(isA<StateError>()),
      );
      platform.failWrites = false;

      final restarted = SettingsController(SharedPreferencesSettingsService());
      await restarted.loadSettings();
      expect(restarted.shotUploadStepSeen, isFalse);
      expect(restarted.shotUploadPendingDecision, isNull);
    },
  );

  test(
    'a failed pending clear remains retryable after reconstruction',
    () async {
      final service = SharedPreferencesSettingsService();
      final controller = SettingsController(service);
      await controller.loadSettings();
      await controller.setShotUploadDecision(false);
      platform.failWrites = true;

      await expectLater(
        controller.clearShotUploadPendingDecision(),
        throwsA(isA<StateError>()),
      );
      platform.failWrites = false;

      final restarted = SettingsController(SharedPreferencesSettingsService());
      await restarted.loadSettings();
      expect(restarted.shotUploadStepSeen, isTrue);
      expect(restarted.shotUploadPendingDecision, isFalse);
    },
  );
}
