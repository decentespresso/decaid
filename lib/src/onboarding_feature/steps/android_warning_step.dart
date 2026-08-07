import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:reaprime/src/onboarding_feature/widgets/onboarding_scaffold.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../onboarding_controller.dart';

const int _fullExperienceSdk = 31;

OnboardingStep createAndroidWarningStep({
  required SettingsController settingsController,
  Future<int?> Function()? sdkVersionProvider,
}) {
  final provider = sdkVersionProvider ?? _defaultSdkVersion;
  return OnboardingStep(
    id: 'androidWarning',
    shouldShow: () async {
      if (settingsController.androidWarningDismissed) return false;
      final sdk = await provider();
      return sdk != null && sdk < _fullExperienceSdk;
    },
    builder: (controller) => _AndroidWarningStepView(
      onboardingController: controller,
      settingsController: settingsController,
    ),
  );
}

Future<int?> _defaultSdkVersion() async {
  if (!Platform.isAndroid) return null;
  final info = await DeviceInfoPlugin().androidInfo;
  return info.version.sdkInt;
}

class _AndroidWarningStepView extends StatelessWidget {
  final OnboardingController onboardingController;
  final SettingsController settingsController;

  const _AndroidWarningStepView({
    required this.onboardingController,
    required this.settingsController,
  });

  Future<void> _continue() async {
    await settingsController.setAndroidWarningDismissed(true);
    onboardingController.advance();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return OnboardingScaffold(
      title: 'Heads up',
      semanticsLabel: 'Android compatibility warning',
      body: [
        Text(
          'Your Android version may have reduced performance and WebView '
          'issues. The full experience works best on Android 12 and newer.',
          style: theme.textTheme.p,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'You can keep going — some screens may just feel slower.',
          style: theme.textTheme.muted,
          textAlign: TextAlign.center,
        ),
      ],
      primaryAction: AccessibleButton(
        label: 'Continue',
        onTap: _continue,
        child: ShadButton(onPressed: _continue, child: const Text('Continue')),
      ),
    );
  }
}

@Preview(name: 'Android Warning Step', group: 'Onboarding')
Widget androidWarningStepPreview() {
  return ShadApp(
    home: Builder(
      builder: (context) {
        final theme = ShadTheme.of(context);
        return OnboardingScaffold(
          title: 'Heads up',
          semanticsLabel: 'Android compatibility warning',
          body: [
            Text(
              'Your Android version may have reduced performance and WebView '
              'issues. The full experience works best on Android 12 and newer.',
              style: theme.textTheme.p,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'You can keep going — some screens may just feel slower.',
              style: theme.textTheme.muted,
              textAlign: TextAlign.center,
            ),
          ],
          primaryAction: ShadButton(
            onPressed: () {},
            child: const Text('Continue'),
          ),
        );
      },
    ),
  );
}
