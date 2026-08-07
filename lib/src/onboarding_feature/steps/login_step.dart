import 'package:flutter/material.dart';
import 'package:reaprime/src/account/decent_login_form.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/widgets/onboarding_scaffold.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

OnboardingStep createLoginStep({
  required DecentAccountService accountService,
  required SettingsController settingsController,
}) {
  return OnboardingStep(
    id: 'login',
    shouldShow: () async =>
        !settingsController.accountStepSeen &&
        !(await accountService.isLoggedIn()),
    builder: (controller) => LoginStepWidget(
      accountService: accountService,
      onComplete: () async {
        await settingsController.setAccountStepSeen(true);
        controller.advance();
      },
    ),
  );
}

class LoginStepWidget extends StatelessWidget {
  final DecentAccountService accountService;
  final VoidCallback onComplete;

  const LoginStepWidget({
    super.key,
    required this.accountService,
    required this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return OnboardingScaffold(
      title: 'Link Your Decent Account',
      semanticsLabel: 'Link your Decent account',
      body: [
        Icon(
          Icons.account_circle_outlined,
          size: 64,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Sync your profiles, beans, and shots across devices.',
          style: theme.textTheme.muted,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        DecentLoginForm(
          accountService: accountService,
          onSuccess: onComplete,
          secondaryLabel: 'Skip for now',
          onSecondary: onComplete,
        ),
      ],
    );
  }
}
