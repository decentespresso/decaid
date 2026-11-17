import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';

void main() {
  for (final stepCount in [1, 2]) {
    test('advance after disposal is harmless with $stepCount steps', () async {
      final controller = OnboardingController(
        steps: [
          for (var i = 0; i < stepCount; i++)
            OnboardingStep(
              id: 'step-$i',
              shouldShow: () async => true,
              builder: (_) => const SizedBox(),
            ),
        ],
      );
      await controller.initialize();
      controller.dispose();
      expect(controller.advance, returnsNormally);
      expect(controller.currentStep.id, 'step-0');
    });
  }

  test('initialize completion after disposal is ignored', () async {
    final shouldShow = Completer<bool>();
    final controller = OnboardingController(
      steps: [
        OnboardingStep(
          id: 'scan',
          shouldShow: () => shouldShow.future,
          builder: (_) => const SizedBox(),
        ),
      ],
    );
    final initialization = controller.initialize();
    controller.dispose();
    shouldShow.complete(true);
    await expectLater(initialization, completes);
    expect(controller.activeSteps, isEmpty);
  });

  test('evaluates shouldShow and skips steps that return false', () async {
    final controller = OnboardingController(
      steps: [
        OnboardingStep(
          id: 'always-skip',
          shouldShow: () async => false,
          builder: (_) => const SizedBox(),
        ),
        OnboardingStep(
          id: 'always-show',
          shouldShow: () async => true,
          builder: (_) => const SizedBox(),
        ),
      ],
    );

    await controller.initialize();
    expect(controller.currentStep.id, 'always-show');
    expect(controller.activeSteps, hasLength(1));
  });

  test('advance() moves to next step', () async {
    final controller = OnboardingController(
      steps: [
        OnboardingStep(
          id: 'step-1',
          shouldShow: () async => true,
          builder: (_) => const SizedBox(),
        ),
        OnboardingStep(
          id: 'step-2',
          shouldShow: () async => true,
          builder: (_) => const SizedBox(),
        ),
      ],
    );

    await controller.initialize();
    expect(controller.currentStep.id, 'step-1');

    controller.advance();
    expect(controller.currentStep.id, 'step-2');
  });

  test('advance() on last step emits completed', () async {
    final controller = OnboardingController(
      steps: [
        OnboardingStep(
          id: 'only-step',
          shouldShow: () async => true,
          builder: (_) => const SizedBox(),
        ),
      ],
    );

    await controller.initialize();

    expectLater(controller.completedStream, emits(true));
    controller.advance();
  });

  test('currentStepStream emits on advance', () async {
    final controller = OnboardingController(
      steps: [
        OnboardingStep(
          id: 'step-1',
          shouldShow: () async => true,
          builder: (_) => const SizedBox(),
        ),
        OnboardingStep(
          id: 'step-2',
          shouldShow: () async => true,
          builder: (_) => const SizedBox(),
        ),
      ],
    );

    await controller.initialize();

    expectLater(
      controller.currentStepStream.map((s) => s.id),
      emitsInOrder(['step-1', 'step-2']),
    );

    controller.advance();
  });
}
