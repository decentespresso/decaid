import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('renders current step widget', (tester) async {
    final controller = OnboardingController(
      steps: [
        OnboardingStep(
          id: 'test-step',
          shouldShow: () async => true,
          builder: (_) => const Text('Step Content'),
        ),
      ],
    );
    await controller.initialize();

    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(body: OnboardingView(controller: controller)),
      ),
    );
    await tester.pump();

    expect(find.text('Step Content'), findsOneWidget);
  });

  testWidgets('blocks system back navigation via PopScope', (tester) async {
    final controller = OnboardingController(
      steps: [
        OnboardingStep(
          id: 'test-step',
          shouldShow: () async => true,
          builder: (_) => const Text('Step Content'),
        ),
      ],
    );
    await controller.initialize();

    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(body: OnboardingView(controller: controller)),
      ),
    );
    await tester.pump();

    final popScope = tester.widget<PopScope>(find.byType(PopScope));
    expect(popScope.canPop, isFalse);
  });
}
