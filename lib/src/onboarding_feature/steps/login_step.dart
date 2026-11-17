import 'package:flutter/material.dart';
import 'package:reaprime/src/account/decent_login_form.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/widgets/onboarding_scaffold.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

OnboardingStep createLoginStep({
  required DecentAccountService accountService,
  required SettingsController settingsController,
}) {
  return OnboardingStep(
    id: 'login',
    shouldShow: () async =>
        !settingsController.accountStepSeen &&
        !(await accountService.hasLinkedAccount()),
    builder: (controller) => LoginStepWidget(
      accountService: accountService,
      onComplete: () async {
        await settingsController.setAccountStepSeen(true);
        controller.advance();
      },
    ),
  );
}

class LoginStepWidget extends StatefulWidget {
  final DecentAccountService accountService;
  final VoidCallback onComplete;

  const LoginStepWidget({
    super.key,
    required this.accountService,
    required this.onComplete,
  });

  @override
  State<LoginStepWidget> createState() => _LoginStepWidgetState();
}

class _LoginStepWidgetState extends State<LoginStepWidget> {
  late Future<bool> _reachability;

  @override
  void initState() {
    super.initState();
    _reachability = widget.accountService.isBackendReachable();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _reachability,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildChecking();
        }
        return snapshot.data == true
            ? _buildLogin(context)
            : _buildOffline(context);
      },
    );
  }

  Widget _buildChecking() {
    return const OnboardingScaffold(
      semanticsLabel: 'Checking internet connection',
      body: [Center(child: SizedBox(width: 200, child: ShadProgress()))],
    );
  }

  Widget _buildLogin(BuildContext context) {
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
          accountService: widget.accountService,
          onSuccess: widget.onComplete,
          secondaryLabel: 'Skip for now',
          onSecondary: widget.onComplete,
        ),
      ],
    );
  }

  Widget _buildOffline(BuildContext context) {
    final theme = ShadTheme.of(context);

    return OnboardingScaffold(
      title: 'Connect to the internet',
      semanticsLabel: 'Internet connection unavailable',
      body: [
        Icon(LucideIcons.wifiOff, size: 64, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'Account login, cloud sync, and skin downloads need an internet '
          'connection. Machine control and installed skins remain available '
          'offline.',
          style: theme.textTheme.muted,
          textAlign: TextAlign.center,
        ),
      ],
      primaryAction: AccessibleButton(
        label: 'Check again',
        onTap: _checkAgain,
        child: ShadButton(
          onPressed: _checkAgain,
          leading: const Icon(LucideIcons.refreshCw, size: 16),
          child: const Text('Check again'),
        ),
      ),
      secondaryAction: AccessibleButton(
        label: 'Continue offline',
        onTap: widget.onComplete,
        child: ShadButton.outline(
          onPressed: widget.onComplete,
          child: const Text('Continue offline'),
        ),
      ),
    );
  }

  void _checkAgain() {
    if (!mounted) return;
    setState(() {
      _reachability = widget.accountService.isBackendReachable();
    });
  }
}
