import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/steps/android_warning_step.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

void main() {
  late SettingsController settings;

  setUp(() {
    settings = SettingsController(MockSettingsService());
  });

  OnboardingStep buildStep({required Future<int?> Function() sdk}) {
    return createAndroidWarningStep(
      settingsController: settings,
      sdkVersionProvider: sdk,
    );
  }

  group('shouldShow', () {
    test('true when Android SDK < 31 and not dismissed', () async {
      final step = buildStep(sdk: () async => 30);
      expect(await step.shouldShow(), isTrue);
    });

    test('false when Android SDK >= 31', () async {
      final step = buildStep(sdk: () async => 31);
      expect(await step.shouldShow(), isFalse);
    });

    test('false when not Android (provider returns null)', () async {
      final step = buildStep(sdk: () async => null);
      expect(await step.shouldShow(), isFalse);
    });

    test('false when already dismissed', () async {
      await settings.setAndroidWarningDismissed(true);
      final step = buildStep(sdk: () async => 28);
      expect(await step.shouldShow(), isFalse);
    });
  });

  testWidgets('Continue persists dismissal and advances', (tester) async {
    final controller = OnboardingController(
      steps: [
        createAndroidWarningStep(
          settingsController: settings,
          sdkVersionProvider: () async => 30,
        ),
        OnboardingStep(
          id: 'next',
          shouldShow: () async => true,
          builder: (_) => const Scaffold(body: Text('next-step')),
        ),
      ],
    );
    await controller.initialize();

    await tester.pumpWidget(
      ShadApp(
        home: Builder(
          builder: (context) => controller.currentStep.builder(controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(settings.androidWarningDismissed, isFalse);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(settings.androidWarningDismissed, isTrue);

    await tester.pumpWidget(
      ShadApp(
        home: Builder(
          builder: (context) => controller.currentStep.builder(controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('next-step'), findsOneWidget);
  });
}
