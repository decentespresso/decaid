import 'package:flutter/material.dart';
import 'package:reaprime/src/onboarding_feature/widgets/onboarding_scaffold.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../onboarding_controller.dart';

OnboardingStep createWelcomeStep() {
  return OnboardingStep(
    id: 'welcome',
    shouldShow: () async => true,
    builder: (controller) => _WelcomeStepView(controller: controller),
  );
}

class _WelcomeStepView extends StatelessWidget {
  final OnboardingController controller;

  const _WelcomeStepView({required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return OnboardingScaffold(
      title: 'Welcome to Decaid',
      semanticsLabel: 'Welcome screen',
      body: [
        Text(
          'Control your Decent espresso machine, manage profiles, and track your shots — right here or from any device on your network.',
          style: theme.textTheme.p,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'Coming from the DE1 app? You can import your data next.',
          style: theme.textTheme.muted,
          textAlign: TextAlign.center,
        ),
      ],
      primaryAction: AccessibleButton(
        label: 'Get Started',
        onTap: controller.advance,
        child: ShadButton(
          onPressed: controller.advance,
          child: const Text('Get Started'),
        ),
      ),
    );
  }
}
