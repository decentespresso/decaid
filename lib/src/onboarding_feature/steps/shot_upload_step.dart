import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/widgets/onboarding_scaffold.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

final _log = Logger('ShotUploadStep');

const shotUploadPluginId = 'shot-upload.reaplugin';
const shotUploadConsentKey = 'plugin:$shotUploadPluginId';
const shotUploadCopy =
    'Your shots stay on this tablet and are yours whether or not you upload '
    'them. Turn this on to send each finished shot to your Decent account at '
    'decentespresso.com, where you can look back, compare, and share them.';
const shotUploadSerialCopy =
    'Each upload includes your espresso machine\'s serial number, so shots '
    'from different machines stay separate. Leaving this off changes nothing '
    'else.';
const shotUploadReversibleCopy = 'You can change this later in Settings.';

OnboardingStep createShotUploadStep({
  required DecentAccountService accountService,
  required SettingsController settingsController,
  required AccountConsentStore consentStore,
}) {
  return OnboardingStep(
    id: 'shot-upload',
    shouldShow: () async => !settingsController.shotUploadStepSeen,
    builder: (controller) => _ShotUploadStepView(
      onboardingController: controller,
      accountService: accountService,
      settingsController: settingsController,
      consentStore: consentStore,
    ),
  );
}

/// Applies the onboarding answer to the bundled plugin settings.
///
/// Runs from [PluginLoaderService.initialize] between the manifest scan and the
/// autoload pass, so the plugin never loads with a stale `AutoUpload` value. It
/// fails closed: when the answer cannot be recorded the plugin is suppressed for
/// the rest of the session instead of loading with whatever was stored before.
Future<void> applyShotUploadIntent(
  SettingsController settings,
  PluginLoaderService plugins,
) async {
  if (!settings.shotUploadStepSeen) return;
  try {
    final desired = settings.shotUploadOptIn;
    final current = await plugins.pluginSettings(shotUploadPluginId);
    if (current['AutoUpload'] != desired) {
      await plugins.savePluginSettings(shotUploadPluginId, {
        'AutoUpload': desired,
      });
    }
    // One-shot: the answer is only a seed for the plugin setting. Once it has
    // landed, the plugin's own AutoUpload is authoritative, so a later change
    // in plugin settings is not overwritten on the next launch.
    await settings.clearShotUploadOptIn();
  } catch (e) {
    plugins.suppressLoad(shotUploadPluginId);
    _log.warning('shot upload intent not applied; plugin not loaded', e);
  }
}

class _ShotUploadStepView extends StatefulWidget {
  final OnboardingController onboardingController;
  final DecentAccountService accountService;
  final SettingsController settingsController;
  final AccountConsentStore consentStore;

  const _ShotUploadStepView({
    required this.onboardingController,
    required this.accountService,
    required this.settingsController,
    required this.consentStore,
  });

  @override
  State<_ShotUploadStepView> createState() => _ShotUploadStepViewState();
}

class _ShotUploadStepViewState extends State<_ShotUploadStepView> {
  late bool _optedIn = widget.settingsController.shotUploadOptIn;
  bool _committing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _skipWithoutAccount();
  }

  Future<void> _skipWithoutAccount() async {
    final linked = await widget.accountService.hasLinkedAccount();
    if (!mounted || linked) return;
    widget.onboardingController.advance();
  }

  Future<void> _continue() async {
    if (_committing) return;
    setState(() {
      _committing = true;
      _error = null;
    });
    try {
      if (_optedIn) {
        await widget.consentStore.write(
          shotUploadConsentKey,
          AccountConsentDecision.allowed,
        );
      }
      await widget.settingsController.setShotUploadOptIn(_optedIn);
      await widget.settingsController.setShotUploadStepSeen(true);
      if (!mounted) return;
      widget.onboardingController.advance();
    } catch (e) {
      _log.warning('shot upload onboarding failed to commit', e);
      if (!mounted) return;
      setState(() {
        _committing = false;
        _error = 'Could not save your choice. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return OnboardingScaffold(
      title: 'Shot upload',
      semanticsLabel: 'Shot upload',
      body: [
        Text(
          shotUploadCopy,
          style: theme.textTheme.p,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          shotUploadSerialCopy,
          style: theme.textTheme.small,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(child: Text('Upload my shots', style: theme.textTheme.p)),
            const SizedBox(width: 12),
            Semantics(
              toggled: _optedIn,
              label: 'Upload my shots',
              child: ExcludeSemantics(
                child: ShadSwitch(
                  value: _optedIn,
                  onChanged: _committing
                      ? null
                      : (value) => setState(() => _optedIn = value),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          shotUploadReversibleCopy,
          style: theme.textTheme.muted,
          textAlign: TextAlign.center,
        ),
        if (_error case final message?) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              message,
              style: theme.textTheme.muted,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ],
      primaryAction: AccessibleButton(
        label: 'Continue',
        onTap: _committing ? null : _continue,
        child: ShadButton(
          onPressed: _committing ? null : _continue,
          child: const Text('Continue'),
        ),
      ),
    );
  }
}
