import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import '../helpers/mock_settings_service.dart';

base class _MemoryAsyncPreferences extends SharedPreferencesAsyncPlatform {
  final values = <String, Object>{};

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) async {
    values[key] = value;
  }

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) async {
    values[key] = value;
  }

  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) async {
    values[key] = value;
  }

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    values[key] = value;
  }

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) async {
    values[key] = value;
  }

  @override
  Future<void> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
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
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async => values[key] as String?;

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) async => values[key] as List<String>?;
}

class _FailingThemeSettingsService extends MockSettingsService {
  @override
  Future<ThemeMode> themeMode() async => throw StateError('theme read failed');
}

void main() {
  final key = SettingsKeys.requireExtensionManagementAuthorization.name;

  group('persisted policy', () {
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

    test('a fresh installation reads compatibility mode', () async {
      expect(platform.values.containsKey(key), isFalse);
      expect(
        await SharedPreferencesSettingsService()
            .requireExtensionManagementAuthorization(),
        isFalse,
      );
    });

    test('an upgraded installation never infers protection', () async {
      platform.values['automaticUpdateCheck'] = true;
      platform.values['defaultSkinId'] = 'streamline.js';
      platform.values['logLevel'] = 'DEBUG';
      platform.values['enableSimulatedWebViews'] = false;

      expect(
        await SharedPreferencesSettingsService()
            .requireExtensionManagementAuthorization(),
        isFalse,
      );
    });

    test('a stored true reads protected mode', () async {
      await SharedPreferencesSettingsService()
          .setRequireExtensionManagementAuthorization(true);
      expect(platform.values[key], isTrue);
      expect(
        await SharedPreferencesSettingsService()
            .requireExtensionManagementAuthorization(),
        isTrue,
      );
    });

    test('a stored false reads compatibility mode', () async {
      platform.values[key] = false;
      expect(
        await SharedPreferencesSettingsService()
            .requireExtensionManagementAuthorization(),
        isFalse,
      );
    });
  });

  group('controller policy', () {
    test('stays protected until the stored policy has been read', () {
      final controller = SettingsController(MockSettingsService());
      expect(controller.requireExtensionManagementAuthorization, isTrue);
    });

    test('loadSettings adopts the persisted compatibility mode', () async {
      final controller = SettingsController(MockSettingsService());
      await controller.loadSettings();
      expect(controller.requireExtensionManagementAuthorization, isFalse);
    });

    test('loadSettings adopts a persisted protected mode', () async {
      final service = MockSettingsService();
      await service.setRequireExtensionManagementAuthorization(true);
      final controller = SettingsController(service);

      await controller.loadSettings();

      expect(controller.requireExtensionManagementAuthorization, isTrue);
    });

    test('loadSettings reads the policy before other settings fail', () async {
      final controller = SettingsController(_FailingThemeSettingsService());

      await expectLater(controller.loadSettings(), throwsA(isA<StateError>()));

      expect(controller.requireExtensionManagementAuthorization, isFalse);
    });

    test('a read error keeps protection and is not fatal', () async {
      final service = MockSettingsService()
        ..failRequireExtensionManagementAuthorizationRead = true;
      final controller = SettingsController(service);

      await controller.loadSettings();

      expect(controller.requireExtensionManagementAuthorization, isTrue);
      expect(
        await controller.currentRequireExtensionManagementAuthorization(),
        isTrue,
      );
    });

    test('the per-request read is fresh, not the display field', () async {
      final service = MockSettingsService();
      final controller = SettingsController(service);
      await controller.loadSettings();
      expect(controller.requireExtensionManagementAuthorization, isFalse);

      await service.setRequireExtensionManagementAuthorization(true);

      expect(
        await controller.currentRequireExtensionManagementAuthorization(),
        isTrue,
      );
      expect(controller.requireExtensionManagementAuthorization, isTrue);
    });

    test('a toggle publishes only after a successful write', () async {
      final service = MockSettingsService();
      final controller = SettingsController(service);
      await controller.loadSettings();
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setRequireExtensionManagementAuthorization(true);

      expect(controller.requireExtensionManagementAuthorization, isTrue);
      expect(service.requireExtensionManagementAuthorizationWrites, 1);
      expect(notifications, 1);
    });

    test('a failed toggle keeps protection and surfaces the error', () async {
      final service = MockSettingsService();
      await service.setRequireExtensionManagementAuthorization(true);
      final controller = SettingsController(service);
      await controller.loadSettings();
      var notifications = 0;
      controller.addListener(() => notifications++);
      service.failRequireExtensionManagementAuthorizationWrite = true;

      await expectLater(
        controller.setRequireExtensionManagementAuthorization(false),
        throwsA(isA<StateError>()),
      );

      expect(controller.requireExtensionManagementAuthorization, isTrue);
      expect(
        await controller.currentRequireExtensionManagementAuthorization(),
        isTrue,
      );
      expect(notifications, 0);
    });

    test('a refresh after an error recovers from storage only', () async {
      final service = MockSettingsService()
        ..failRequireExtensionManagementAuthorizationRead = true;
      final controller = SettingsController(service);
      await controller.loadSettings();
      expect(
        await controller.currentRequireExtensionManagementAuthorization(),
        isTrue,
      );

      service.failRequireExtensionManagementAuthorizationRead = false;
      await controller.setRequireExtensionManagementAuthorization(false);

      expect(controller.requireExtensionManagementAuthorization, isFalse);
      expect(
        await controller.currentRequireExtensionManagementAuthorization(),
        isFalse,
      );
    });

    test('overlapping refresh and toggle publish in order', () async {
      final service = MockSettingsService();
      final controller = SettingsController(service);
      await controller.loadSettings();
      expect(controller.requireExtensionManagementAuthorization, isFalse);

      final gate = Completer<void>();
      service.requireExtensionManagementAuthorizationReadGate = gate;
      final refresh = controller
          .currentRequireExtensionManagementAuthorization();
      await Future<void>.delayed(Duration.zero);
      final toggle = controller.setRequireExtensionManagementAuthorization(
        true,
      );
      await Future<void>.delayed(Duration.zero);
      service.requireExtensionManagementAuthorizationReadGate = null;
      gate.complete();

      expect(await refresh, isFalse);
      await toggle;
      expect(controller.requireExtensionManagementAuthorization, isTrue);
      expect(await service.requireExtensionManagementAuthorization(), isTrue);
    });

    test('overlapping native toggles settle on the last write', () async {
      final service = MockSettingsService();
      final controller = SettingsController(service);
      await controller.loadSettings();

      final protect = controller.setRequireExtensionManagementAuthorization(
        true,
      );
      final relax = controller.setRequireExtensionManagementAuthorization(
        false,
      );

      await Future.wait([protect, relax]);
      expect(controller.requireExtensionManagementAuthorization, isFalse);
      expect(await service.requireExtensionManagementAuthorization(), isFalse);
    });
  });
}
