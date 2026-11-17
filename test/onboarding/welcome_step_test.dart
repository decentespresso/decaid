import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/steps/welcome_step.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  group('createWelcomeStep', () {
    test('shouldShow returns true', () async {
      final step = createWelcomeStep();
      expect(await step.shouldShow(), isTrue);
    });

    testWidgets('displays welcome copy', (tester) async {
      final controller = OnboardingController(
        steps: [
          createWelcomeStep(),
          OnboardingStep(
            id: 'next',
            shouldShow: () async => true,
            builder: (_) => const SizedBox(),
          ),
        ],
      );
      await controller.initialize();

      await tester.pumpWidget(
        ShadApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => controller.currentStep.builder(controller),
            ),
          ),
        ),
      );

      expect(find.text('Welcome to Decaid'), findsOneWidget);
      expect(
        find.text(
          'Control your Decent espresso machine, manage profiles, and track your shots — right here or from any device on your network.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Coming from De1App? You can import your data next.'),
        findsOneWidget,
      );
      expect(find.text('Get Started'), findsOneWidget);
    });

    testWidgets('Get Started button advances controller', (tester) async {
      final controller = OnboardingController(
        steps: [
          createWelcomeStep(),
          OnboardingStep(
            id: 'next',
            shouldShow: () async => true,
            builder: (_) => const SizedBox(),
          ),
        ],
      );
      await controller.initialize();

      await tester.pumpWidget(
        ShadApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => controller.currentStep.builder(controller),
            ),
          ),
        ),
      );

      expect(controller.currentStep.id, 'welcome');

      await tester.tap(find.text('Get Started'));
      await tester.pump();

      expect(controller.currentStep.id, 'next');
    });
  });
}
