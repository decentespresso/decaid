import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

base class _MemoryAsyncPreferences extends SharedPreferencesAsyncPlatform {
  final values = <String, Object>{};
  final written = <String>[];
  int writes = 0;
  int? failFromWrite;

  void _recordWrite(String key) {
    writes++;
    final failFrom = failFromWrite;
    if (failFrom != null && writes >= failFrom) {
      throw StateError('write failed');
    }
    written.add(key);
  }

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
    values[key] = value;
  }

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
    values[key] = value;
  }

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
    values[key] = value;
  }

  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
    values[key] = value;
  }

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
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

  Future<SettingsController> configuredInstallation() async {
    final service = SharedPreferencesSettingsService();
    await service.setOnboardingCompleted(true);
    await service.setAccountStepSeen(true);
    await service.setAndroidWarningDismissed(true);
    await service.setShotUploadDecision(true);
    await service.clearShotUploadPendingDecision();
    await service.setDefaultSkinId('custom.js');
    await service.setPreferredMachineId('de1-serial-123');
    platform.values['plugin.settings.shot-upload.reaplugin'] = jsonEncode({
      'AutoUpload': true,
      'autoload': false,
    });
    final controller = SettingsController(SharedPreferencesSettingsService());
    await controller.loadSettings();
    return controller;
  }

  test('arming a replay leaves the running session untouched', () async {
    final controller = await configuredInstallation();
    var notifications = 0;
    controller.addListener(() => notifications++);
    platform.written.clear();

    await controller.requestOnboardingReplay();
    await controller.requestOnboardingReplay();

    expect(platform.written.toSet(), {
      SettingsKeys.onboardingReplayRequested.name,
    });
    expect(
      platform.values[SettingsKeys.onboardingReplayRequested.name],
      isTrue,
    );
    expect(notifications, 0, reason: 'nothing is presented or re-run now');
    expect(controller.onboardingCompleted, isTrue);
    expect(controller.accountStepSeen, isTrue);
    expect(controller.androidWarningDismissed, isTrue);
    expect(controller.shotUploadStepSeen, isTrue);
    expect(platform.values[SettingsKeys.onboardingCompleted.name], isTrue);
    expect(
      jsonDecode(
        platform.values[SettingsKeys.shotUploadDecision.name] as String,
      ),
      {'answer': true, 'pending': false, 'seen': true},
    );
  });

  test('a soft reload does not consume an armed replay', () async {
    final controller = await configuredInstallation();
    await controller.requestOnboardingReplay();

    final reloaded = SettingsController(SharedPreferencesSettingsService());
    await reloaded.loadSettings();

    expect(reloaded.onboardingCompleted, isTrue);
    expect(reloaded.accountStepSeen, isTrue);
    expect(reloaded.androidWarningDismissed, isTrue);
    expect(reloaded.shotUploadStepSeen, isTrue);
    expect(
      platform.values[SettingsKeys.onboardingReplayRequested.name],
      isTrue,
    );
  });

  test(
    'cold startup consumes the request once and later launches keep it',
    () async {
      final controller = await configuredInstallation();
      await controller.requestOnboardingReplay();

      expect(await controller.consumeOnboardingReplayRequest(), isTrue);
      expect(controller.onboardingCompleted, isFalse);
      expect(controller.accountStepSeen, isFalse);
      expect(controller.androidWarningDismissed, isFalse);
      expect(controller.shotUploadStepSeen, isFalse);
      expect(
        platform.values[SettingsKeys.onboardingReplayRequested.name],
        isFalse,
      );

      expect(
        await controller.consumeOnboardingReplayRequest(),
        isFalse,
        reason: 'a second consumer in the same process finds nothing armed',
      );

      await controller.setOnboardingCompleted(true);
      await controller.setAccountStepSeen(true);
      await controller.setAndroidWarningDismissed(true);
      await controller.setShotUploadStepSeen(true);

      final nextLaunch = SettingsController(SharedPreferencesSettingsService());
      await nextLaunch.loadSettings();
      expect(await nextLaunch.consumeOnboardingReplayRequest(), isFalse);
      expect(nextLaunch.onboardingCompleted, isTrue);
      expect(nextLaunch.accountStepSeen, isTrue);
      expect(nextLaunch.androidWarningDismissed, isTrue);
      expect(nextLaunch.shotUploadStepSeen, isTrue);
    },
  );

  test(
    'replay re-arms the step without consuming a pending decision',
    () async {
      await SharedPreferencesSettingsService().setShotUploadDecision(true);
      final controller = SettingsController(SharedPreferencesSettingsService());
      await controller.loadSettings();
      expect(controller.shotUploadPendingDecision, isTrue);

      await controller.requestOnboardingReplay();
      expect(await controller.consumeOnboardingReplayRequest(), isTrue);

      expect(controller.shotUploadStepSeen, isFalse);
      expect(
        controller.shotUploadPendingDecision,
        isTrue,
        reason: 'a genuine pending answer survives the replay',
      );
      expect(
        jsonDecode(
          platform.values[SettingsKeys.shotUploadDecision.name] as String,
        ),
        {'answer': true, 'pending': true, 'seen': false},
      );
    },
  );

  test('replay writes only presentation progress and the marker', () async {
    final controller = await configuredInstallation();
    await controller.requestOnboardingReplay();
    platform.written.clear();

    await controller.consumeOnboardingReplayRequest();

    expect(platform.written.toSet(), {
      SettingsKeys.onboardingCompleted.name,
      SettingsKeys.accountStepSeen.name,
      SettingsKeys.androidWarningDismissed.name,
      SettingsKeys.shotUploadDecision.name,
      SettingsKeys.onboardingReplayRequested.name,
    });
    expect(platform.values[SettingsKeys.defaultSkinId.name], 'custom.js');
    expect(
      platform.values[SettingsKeys.preferredMachineId.name],
      'de1-serial-123',
    );
    expect(
      jsonDecode(
        platform.values['plugin.settings.shot-upload.reaplugin'] as String,
      ),
      {'AutoUpload': true, 'autoload': false},
    );
    expect(
      jsonDecode(
        platform.values[SettingsKeys.shotUploadDecision.name] as String,
      ),
      {'answer': true, 'pending': false, 'seen': false},
    );
  });

  test('a failed progress write keeps the request armed and retries', () async {
    final controller = await configuredInstallation();
    await controller.requestOnboardingReplay();

    platform.failFromWrite = platform.writes + 2;
    await expectLater(
      controller.consumeOnboardingReplayRequest(),
      throwsA(isA<StateError>()),
    );

    expect(controller.onboardingCompleted, isTrue);
    expect(controller.accountStepSeen, isTrue);
    expect(controller.androidWarningDismissed, isTrue);
    expect(controller.shotUploadStepSeen, isTrue);
    expect(
      platform.values[SettingsKeys.onboardingReplayRequested.name],
      isTrue,
      reason: 'the next launch has to retry the request',
    );

    platform.failFromWrite = null;
    expect(await controller.consumeOnboardingReplayRequest(), isTrue);
    expect(controller.onboardingCompleted, isFalse);
    expect(controller.accountStepSeen, isFalse);
    expect(controller.androidWarningDismissed, isFalse);
    expect(controller.shotUploadStepSeen, isFalse);
    expect(
      platform.values[SettingsKeys.onboardingReplayRequested.name],
      isFalse,
    );

    final relaunched = SettingsController(SharedPreferencesSettingsService());
    await relaunched.loadSettings();
    expect(relaunched.onboardingCompleted, isFalse);
    expect(relaunched.accountStepSeen, isFalse);
    expect(relaunched.androidWarningDismissed, isFalse);
    expect(relaunched.shotUploadStepSeen, isFalse);
  });

  test('the recorded answer outlives a successful handoff', () async {
    final service = SharedPreferencesSettingsService();
    await service.setShotUploadDecision(true);
    expect(await service.shotUploadRecordedAnswer(), isTrue);
    expect(await service.shotUploadPendingDecision(), isTrue);

    await service.clearShotUploadPendingDecision();

    expect(await service.shotUploadPendingDecision(), isNull);
    expect(await service.shotUploadRecordedAnswer(), isTrue);
    expect(await service.shotUploadStepSeen(), isTrue);
  });
}
