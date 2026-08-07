import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A single step in the troubleshooting wizard.
class TroubleshootingStep {
  final String id;
  final String title;
  final String description;
  final String buttonText;
  final bool Function() shouldShow;

  /// Optional extra widget shown between description and button.
  final Widget Function(BuildContext context)? extraBuilder;

  const TroubleshootingStep({
    required this.id,
    required this.title,
    required this.description,
    required this.buttonText,
    required this.shouldShow,
    this.extraBuilder,
  });
}

/// Returns the troubleshooting steps for the given state.
///
/// Exposed for testing so that shouldShow logic can be unit-tested directly.
/// [isIOS] defaults to `Platform.isIOS` but can be overridden in tests.
/// [isMacOS] defaults to `Platform.isMacOS` but can be overridden in tests.
List<TroubleshootingStep> troubleshootingSteps({
  required AdapterState adapterState,
  bool? isIOS,
  bool? isMacOS,
}) {
  final runningOnIOS = isIOS ?? Platform.isIOS;
  final runningOnMacOS = isMacOS ?? Platform.isMacOS;

  return [
    TroubleshootingStep(
      id: 'machine_power',
      title: 'Is your machine powered on?',
      description:
          'Make sure your Decent Espresso machine is turned on and has finished its startup sequence.',
      buttonText: "Yes, it's on",
      shouldShow: () => true,
    ),
    TroubleshootingStep(
      id: 'bluetooth',
      title: adapterState == AdapterState.unauthorized
          ? 'Bluetooth Permission Required'
          : 'Is Bluetooth enabled?',
      description: adapterState == AdapterState.unauthorized
          ? 'Decaid needs Bluetooth permission to discover your espresso machine. '
                'Go to Settings > Privacy & Security > Bluetooth and enable it for Decaid.'
          : 'Bluetooth adapter state: ${adapterState.name}',
      buttonText: 'Continue',
      shouldShow: () => runningOnIOS && adapterState != AdapterState.poweredOn,
      extraBuilder: (context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AccessibleButton(
          label: 'Open Settings',
          onTap: () => openAppSettings(),
          child: ShadButton.outline(
            size: ShadButtonSize.sm,
            onPressed: () => openAppSettings(),
            child: const Text('Open Settings'),
          ),
        ),
      ),
    ),
    TroubleshootingStep(
      id: 'other_apps',
      title: 'Is another app connected?',
      description:
          'Only one app can connect to your machine via Bluetooth at a time. Close any other Decent apps (e.g., the original Decent app) and try again.',
      buttonText: "I've closed other apps",
      shouldShow: () => true,
    ),
    TroubleshootingStep(
      id: 'system_bt',
      title: 'Check System Bluetooth Settings',
      description:
          'On macOS, if your DE1 appears as "Connected" in System Settings > Bluetooth, the system may hide it from app-level scans. Disconnect it there, then try scanning again.',
      buttonText: "I've checked",
      shouldShow: () => runningOnMacOS,
    ),
  ];
}

/// Shows the troubleshooting wizard dialog.
/// Returns when the dialog is dismissed (either completed or tapped outside).
Future<void> showTroubleshootingWizard({
  required BuildContext context,
  required AdapterState adapterState,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) =>
        _TroubleshootingWizardDialog(adapterState: adapterState),
  );
}

class _TroubleshootingWizardDialog extends StatefulWidget {
  final AdapterState adapterState;

  const _TroubleshootingWizardDialog({required this.adapterState});

  @override
  State<_TroubleshootingWizardDialog> createState() =>
      _TroubleshootingWizardDialogState();
}

class _TroubleshootingWizardDialogState
    extends State<_TroubleshootingWizardDialog> {
  late final List<TroubleshootingStep> _visibleSteps;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    final allSteps = troubleshootingSteps(adapterState: widget.adapterState);
    _visibleSteps = allSteps.where((s) => s.shouldShow()).toList();
  }

  void _advance() {
    if (_currentIndex >= _visibleSteps.length - 1) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _currentIndex++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = _visibleSteps[_currentIndex];
    final theme = ShadTheme.of(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(step.title, style: theme.textTheme.h4),
              const SizedBox(height: 12),
              Text(step.description, style: theme.textTheme.muted),
              const SizedBox(height: 20),
              if (step.extraBuilder != null) step.extraBuilder!(context),
              Align(
                alignment: Alignment.centerRight,
                child: AccessibleButton(
                  label: step.buttonText,
                  onTap: _advance,
                  child: ShadButton(
                    onPressed: _advance,
                    child: Text(step.buttonText),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
