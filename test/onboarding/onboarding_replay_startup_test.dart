import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/main.dart' show prepareOnboardingStartup;
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_settings_service.dart';

const _legacyAutoUploadKey = 'plugin.settings.shot-upload.reaplugin';

void main() {
  setUp(() {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({
      _legacyAutoUploadKey: '{"AutoUpload":true}',
    });
  });

  tearDown(() {
    SharedPreferences.resetStatic();
  });

  Future<(SettingsController, MockSettingsService)> startup({
    required bool seen,
    required bool armed,
  }) async {
    final service = MockSettingsService();
    await service.setShotUploadStepSeen(seen);
    if (armed) await service.setOnboardingReplayRequested(true);
    final settings = SettingsController(service);
    await settings.loadSettings();
    return (settings, service);
  }

  test(
    'the legacy AutoUpload migration runs first so replay still re-arms',
    () async {
      final (settings, service) = await startup(seen: false, armed: true);

      await prepareOnboardingStartup(
        settings,
        forceOnboarding: false,
        bypassOnboarding: false,
      );

      expect(
        settings.shotUploadStepSeen,
        isFalse,
        reason: 'the migration must not swallow the armed replay',
      );
      expect(settings.onboardingCompleted, isFalse);
      expect(settings.accountStepSeen, isFalse);
      expect(settings.androidWarningDismissed, isFalse);
      expect(
        await service.onboardingReplayRequested(),
        isFalse,
        reason: 'a cold launch consumes the request',
      );
    },
  );

  test('without a request the migration still marks the step seen', () async {
    final (settings, _) = await startup(seen: false, armed: false);

    await prepareOnboardingStartup(
      settings,
      forceOnboarding: false,
      bypassOnboarding: false,
    );

    expect(settings.shotUploadStepSeen, isTrue);
    expect(settings.onboardingCompleted, isTrue);
  });

  test('an unarmed startup changes no presentation progress', () async {
    final (settings, service) = await startup(seen: true, armed: false);

    await prepareOnboardingStartup(
      settings,
      forceOnboarding: false,
      bypassOnboarding: false,
    );

    expect(settings.onboardingCompleted, isTrue);
    expect(settings.accountStepSeen, isTrue);
    expect(settings.androidWarningDismissed, isTrue);
    expect(settings.shotUploadStepSeen, isTrue);
    expect(await service.onboardingReplayRequested(), isFalse);
  });

  test('bypass onboarding wins over an armed replay', () async {
    final (settings, service) = await startup(seen: true, armed: true);

    await prepareOnboardingStartup(
      settings,
      forceOnboarding: false,
      bypassOnboarding: true,
    );

    expect(settings.shotUploadStepSeen, isTrue);
    expect(
      await service.onboardingReplayRequested(),
      isFalse,
      reason: 'the explicit flag still consumes the pending request',
    );
  });

  test('force onboarding keeps the step armed', () async {
    final (settings, _) = await startup(seen: true, armed: true);

    await prepareOnboardingStartup(
      settings,
      forceOnboarding: true,
      bypassOnboarding: false,
    );

    expect(settings.shotUploadStepSeen, isFalse);
  });

  test('a failed replay at startup stays armed for the next launch', () async {
    final service = MockSettingsService()
      ..failOnboardingPresentationWrite = true;
    await service.setOnboardingReplayRequested(true);
    final settings = SettingsController(service);
    await settings.loadSettings();

    await prepareOnboardingStartup(
      settings,
      forceOnboarding: false,
      bypassOnboarding: false,
    );

    expect(settings.onboardingCompleted, isTrue);
    expect(settings.accountStepSeen, isTrue);
    expect(settings.androidWarningDismissed, isTrue);
    expect(settings.shotUploadStepSeen, isTrue);
    expect(await service.onboardingReplayRequested(), isTrue);
  });
}
