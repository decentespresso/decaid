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
    'Upload your shot history to your account at decentespresso.com. Look '
    'back, compare and share them with ease.';
const shotUploadReversibleCopy = 'You can change this later in Settings.';

OnboardingStep createShotUploadStep({
  required DecentAccountService accountService,
  required SettingsController settingsController,
}) {
  return OnboardingStep(
    id: 'shot-upload',
    shouldShow: () async => !settingsController.shotUploadStepSeen,
    builder: (controller) => _ShotUploadStepView(
      onboardingController: controller,
      accountService: accountService,
      settingsController: settingsController,
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
  PluginLoaderService plugins, {
  AccountConsentStore? consentStore,
}) async {
  final desired = settings.shotUploadPendingDecision;
  if (desired == null) return;
  try {
    final current = await plugins.pluginSettings(shotUploadPluginId);
    if (current['AutoUpload'] != desired) {
      await plugins.savePluginSettings(shotUploadPluginId, {
        'AutoUpload': desired,
      });
    }
    if (desired) {
      if (consentStore == null) throw StateError('account consent unavailable');
      await consentStore.write(
        shotUploadConsentKey,
        AccountConsentDecision.allowed,
      );
    }
    await settings.clearShotUploadPendingDecision();
  } catch (e) {
    plugins.suppressLoad(shotUploadPluginId);
    _log.warning('shot upload intent not applied; plugin not loaded', e);
  }
}

class _ShotUploadStepView extends StatefulWidget {
  final OnboardingController onboardingController;
  final DecentAccountService accountService;
  final SettingsController settingsController;
  const _ShotUploadStepView({
    required this.onboardingController,
    required this.accountService,
    required this.settingsController,
  });

  @override
  State<_ShotUploadStepView> createState() => _ShotUploadStepViewState();
}

class _ShotUploadStepViewState extends State<_ShotUploadStepView> {
  late bool _optedIn =
      widget.settingsController.shotUploadPendingDecision ?? false;
  bool? _linkedAccount;
  bool _committing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkAccount();
  }

  Future<void> _checkAccount() async {
    try {
      final linked = await widget.accountService.hasLinkedAccount();
      if (!mounted) return;
      if (!linked) {
        widget.onboardingController.advance();
        return;
      }
      setState(() => _linkedAccount = true);
    } catch (e) {
      _log.warning('failed to check linked account', e);
      if (mounted) {
        setState(() => _error = 'Could not check your account. Try again.');
      }
    }
  }

  Future<void> _retryAccountCheck() async {
    if (_committing) return;
    setState(() {
      _error = null;
      _linkedAccount = null;
    });
    await _checkAccount();
  }

  Future<void> _continue() async {
    if (_committing) return;
    setState(() {
      _committing = true;
      _error = null;
    });
    try {
      await widget.settingsController.setShotUploadDecision(_optedIn);
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
    final primaryLabel = _optedIn ? 'Continue' : 'Not now';
    if (_linkedAccount != true) {
      if (_error == null) return const SizedBox.shrink();
      return OnboardingScaffold(
        title: 'Shot upload',
        semanticsLabel: 'Shot upload',
        body: [
          Text(_error!, style: theme.textTheme.p, textAlign: TextAlign.center),
        ],
        primaryAction: AccessibleButton(
          label: 'Retry',
          onTap: _retryAccountCheck,
          child: ShadButton(
            onPressed: _retryAccountCheck,
            child: const Text('Retry'),
          ),
        ),
      );
    }

    return OnboardingScaffold(
      title: 'Shot upload',
      semanticsLabel: 'Shot upload',
      body: [
        Text(
          shotUploadCopy,
          style: theme.textTheme.p,
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
              onTap: _committing
                  ? null
                  : () => setState(() => _optedIn = !_optedIn),
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
        label: primaryLabel,
        onTap: _committing ? null : _continue,
        child: ShadButton(
          onPressed: _committing ? null : _continue,
          child: Text(primaryLabel),
        ),
      ),
    );
  }
}
