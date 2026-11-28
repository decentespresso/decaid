import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/account/app_log_upload_section.dart';
import 'package:reaprime/src/account/decent_login_form.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/widgets/onboarding_scaffold.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

OnboardingStep createLoginStep({
  required DecentAccountService accountService,
  required SettingsController settingsController,
  AppLogUploadService? appLogUploadService,
}) {
  return OnboardingStep(
    id: 'login',
    shouldShow: () async =>
        !settingsController.accountStepSeen &&
        !(await accountService.hasLinkedAccount()),
    builder: (controller) => LoginStepWidget(
      accountService: accountService,
      appLogUploadService: appLogUploadService,
      onComplete: () async {
        await settingsController.setAccountStepSeen(true);
        controller.advance();
      },
    ),
  );
}

class LoginStepWidget extends StatefulWidget {
  final DecentAccountService accountService;
  final AppLogUploadService? appLogUploadService;
  final VoidCallback onComplete;

  const LoginStepWidget({
    super.key,
    required this.accountService,
    this.appLogUploadService,
    required this.onComplete,
  });

  @override
  State<LoginStepWidget> createState() => _LoginStepWidgetState();
}

class _LoginStepWidgetState extends State<LoginStepWidget> {
  static final _log = Logger('LoginStep');

  late Future<bool> _reachability;
  bool _shareLogs = false;

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
        if (widget.appLogUploadService != null) ...[
          const SizedBox(height: 24),
          ShadSwitch(
            key: const Key('onboarding-app-log-upload'),
            value: _shareLogs,
            onChanged: (value) => setState(() => _shareLogs = value),
            label: const Text(appLogUploadLabel),
            sublabel: const Text(appLogUploadCopy),
          ),
        ],
        const SizedBox(height: 32),
        DecentLoginForm(
          accountService: widget.accountService,
          onSuccess: _onSignedIn,
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

  Future<void> _onSignedIn() async {
    final uploadService = widget.appLogUploadService;
    if (_shareLogs && uploadService != null) {
      try {
        await uploadService.setEnabled(true);
      } catch (e, st) {
        _log.warning('Failed to enable app log sharing', e, st);
      }
    }
    widget.onComplete();
  }

  void _checkAgain() {
    if (!mounted) return;
    setState(() {
      _reachability = widget.accountService.isBackendReachable();
    });
  }
}
