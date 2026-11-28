import 'package:flutter/material.dart';
import 'package:reaprime/src/services/storage/new_owner_recovery_admission.dart';
import 'package:reaprime/src/ui/startup_failure_shell.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Startup presentation for a blocked or uncertain new-owner recovery state.
///
/// It starts no account, upload, plugin, skin, API or database service and
/// offers no reset action: recovery infrastructure never enables destructive
/// reset.
class NewOwnerRecoveryApp extends StatelessWidget {
  const NewOwnerRecoveryApp({
    super.key,
    required this.admission,
    this.logFilePath,
  });

  final NewOwnerRecoveryAdmissionDecision admission;
  final String? logFilePath;

  @override
  Widget build(BuildContext context) {
    if (admission.permitsNormalStartup) {
      throw ArgumentError.value(
        admission.kind,
        'admission',
        'normal startup is not a recovery presentation',
      );
    }
    return StartupFailureShell(
      child: _NewOwnerRecoveryView(
        admission: admission,
        logFilePath: logFilePath,
      ),
    );
  }
}

/// Startup presentation for a failure that happens before normal startup.
///
/// It needs no plugin, resolved path or readable recovery record, so it still
/// renders when diagnostic storage is unavailable, and it offers no reset
/// action.
class NewOwnerRecoveryStartupErrorApp extends StatelessWidget {
  const NewOwnerRecoveryStartupErrorApp({
    super.key,
    required this.detail,
    this.logFilePath,
  });

  final String detail;
  final String? logFilePath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StartupFailureShell(
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    Text(
                      'Decaid could not start',
                      style: theme.textTheme.headlineSmall,
                    ),
                    Text(
                      'Decaid stopped before starting its normal services and '
                      'did not fall back to a reduced start.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    SelectableText(detail),
                    if (logFilePath != null)
                      Text(
                        'Log file: $logFilePath',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NewOwnerRecoveryView extends StatelessWidget {
  const _NewOwnerRecoveryView({
    required this.admission,
    required this.logFilePath,
  });

  final NewOwnerRecoveryAdmissionDecision admission;
  final String? logFilePath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const padding = EdgeInsets.all(24);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: padding,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  Text(
                    _title(admission.kind),
                    style: theme.textTheme.headlineSmall,
                  ),
                  Text(
                    'Decaid has not started its normal services.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    _body(admission.kind),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const Text(
                    'Do not clear app data or reinstall Decaid while this '
                    'message is shown. The recovery record is stored with the '
                    'app and clearing app data removes it.',
                  ),
                  if (admission.detail != null)
                    ShadAlert.destructive(
                      icon: const Icon(Icons.report_problem_outlined),
                      title: const Text('Recovery status'),
                      description: Text(admission.detail!),
                    ),
                  if (logFilePath != null)
                    Text(
                      'Log file: $logFilePath',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _title(NewOwnerRecoveryAdmission kind) {
    switch (kind) {
      case NewOwnerRecoveryAdmission.resetInProgress:
        return 'Preparing this Decaid for a new owner';
      case NewOwnerRecoveryAdmission.readyForNewOwner:
      case NewOwnerRecoveryAdmission.handoffArmedThisProcess:
        return 'Prepared for a new owner';
      case NewOwnerRecoveryAdmission.handoffEligible:
        return 'Ready to start for its new owner';
      case NewOwnerRecoveryAdmission.uncertain:
        return 'Decaid recovery state could not be read';
      case NewOwnerRecoveryAdmission.normalStartup:
        return 'Decaid';
    }
  }

  String _body(NewOwnerRecoveryAdmission kind) {
    switch (kind) {
      case NewOwnerRecoveryAdmission.resetInProgress:
        return 'A reset to hand this device to a new owner started and did not '
            'finish. Decaid only continues once that reset is resumed and '
            'verified, so no mixed-owner state is shown.';
      case NewOwnerRecoveryAdmission.readyForNewOwner:
        return 'The reset finished. Normal startup stays blocked until the '
            'handoff is acknowledged.';
      case NewOwnerRecoveryAdmission.handoffArmedThisProcess:
        return 'Close Decaid. This process must not consume its own handoff.';
      case NewOwnerRecoveryAdmission.handoffEligible:
        return 'An earlier process prepared this device, so it is eligible for '
            'guarded customer startup. Decaid will not start the customer '
            'setup by itself, because the marker alone does not prove the '
            'previous owner data was erased.';
      case NewOwnerRecoveryAdmission.uncertain:
        return 'The new-owner recovery record is unreadable or ambiguous. '
            'Decaid fails closed rather than starting with unknown ownership.';
      case NewOwnerRecoveryAdmission.normalStartup:
        return '';
    }
  }
}
