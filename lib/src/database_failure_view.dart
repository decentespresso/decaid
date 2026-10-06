import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:reaprime/src/services/export/archive_export.dart';
import 'package:reaprime/src/services/storage/database_recovery.dart';
import 'package:reaprime/src/ui/startup_failure_shell.dart';
import 'package:reaprime/src/ui/share_origin.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DatabaseFailureView extends StatefulWidget {
  const DatabaseFailureView({
    super.key,
    required this.logFilePath,
    required this.onSavePackage,
    required this.onResetDatabase,
    this.detail,
  });

  final String logFilePath;
  final String? detail;
  final Future<DeliveryOutcome> Function(Rect sharePositionOrigin)
  onSavePackage;
  final Future<ResetReport> Function() onResetDatabase;

  @override
  State<DatabaseFailureView> createState() => _DatabaseFailureViewState();
}

class _DatabaseFailureViewState extends State<DatabaseFailureView> {
  bool _operationInFlight = false;
  bool _savedThisSession = false;
  String? _status;

  Future<void> _savePackage(Rect sharePositionOrigin) async {
    if (_operationInFlight) return;
    setState(() => _operationInFlight = true);
    try {
      final outcome = await widget.onSavePackage(sharePositionOrigin);
      if (!mounted) return;
      if (outcome == DeliveryOutcome.saved) {
        setState(() {
          _savedThisSession = true;
          _status = 'Recovery package saved.';
        });
      } else {
        setState(() => _status = null);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'Could not save the recovery package: $error';
        });
      }
    } finally {
      if (mounted) setState(() => _operationInFlight = false);
    }
  }

  Future<void> _resetDatabase() async {
    if (_operationInFlight) return;
    setState(() => _operationInFlight = true);
    try {
      final confirmed = await showShadDialog<bool>(
        context: context,
        builder: (context) => ShadDialog(
          title: const Text('Reset local database?'),
          description: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              const Text(
                'This will remove the local database, its WAL and SHM files, '
                'and the local Hive store.',
              ),
              if (!_savedThisSession)
                const Text(
                  'No recovery package has been saved this session. This '
                  'data may not be recoverable.',
                ),
            ],
          ),
          actions: [
            ShadButton.outline(
              onPressed: () => Navigator.of(context).pop(false),
              child: const SizedBox(
                width: 80,
                child: FittedBox(fit: BoxFit.scaleDown, child: Text('Cancel')),
              ),
            ),
            ShadButton.destructive(
              onPressed: () => Navigator.of(context).pop(true),
              child: SizedBox(
                width: 180,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    _savedThisSession
                        ? 'Reset local database'
                        : 'Reset without a saved copy',
                  ),
                ),
              ),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final report = await widget.onResetDatabase();
      if (!mounted) return;
      setState(() {
        _status = report.isClean
            ? 'Data cleared. Close and reopen Decaid.'
            : _resetFailureStatus(report);
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Could not reset the local database: $error');
      }
    } finally {
      if (mounted) setState(() => _operationInFlight = false);
    }
  }

  String _resetFailureStatus(ResetReport report) {
    final details = <String>[];
    if (report.renameFailures.isNotEmpty) {
      details.add('could not rename: ${report.renameFailures.join(', ')}');
    }
    if (report.leftovers.isNotEmpty) {
      details.add('could not delete: ${report.leftovers.join(', ')}');
    }
    return 'Could not clear all data: ${details.join('; ')}';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = ShadTheme.of(context).textTheme;
    final detail = widget.detail;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ShadAlert.destructive(
                icon: const Icon(LucideIcons.databaseZap, size: 16),
                title: const Text(
                  'The local database could not be safely opened or updated',
                ),
                description: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    const Text(
                      'Decaid stopped because its local database could not be '
                      'opened or updated. Your existing data has been left in '
                      'place.',
                    ),
                    if (detail != null)
                      Text('Diagnostic: $detail', style: textTheme.muted),
                    Text(
                      'Log file: ${widget.logFilePath}',
                      style: textTheme.muted,
                    ),
                    const Text(
                      'Please preserve your data and share your logs (and a '
                      'data package if one is available) with Decent support, '
                      'then use an updated Decaid build or assisted repair '
                      'before trying again.',
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: Builder(
                        builder: (context) => ShadButton.outline(
                          enabled: !_operationInFlight,
                          onPressed: () =>
                              _savePackage(shareOriginFor(context)),
                          child: const SizedBox(
                            width: 100,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text('Save recovery package'),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: ShadButton.destructive(
                        enabled: !_operationInFlight,
                        onPressed: _resetDatabase,
                        child: const SizedBox(
                          width: 100,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('Reset local database'),
                          ),
                        ),
                      ),
                    ),
                    if (_status != null) Text(_status!),
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

class DatabaseFailureApp extends StatelessWidget {
  const DatabaseFailureApp({
    super.key,
    required this.logFilePath,
    required this.onSavePackage,
    required this.onResetDatabase,
    this.detail,
  });

  final String logFilePath;
  final String? detail;
  final Future<DeliveryOutcome> Function(Rect sharePositionOrigin)
  onSavePackage;
  final Future<ResetReport> Function() onResetDatabase;

  @override
  Widget build(BuildContext context) {
    return StartupFailureShell(
      child: DatabaseFailureView(
        logFilePath: logFilePath,
        detail: detail,
        onSavePackage: onSavePackage,
        onResetDatabase: onResetDatabase,
      ),
    );
  }
}

@Preview(name: 'Database Startup Failure', group: 'Startup')
Widget databaseStartupFailurePreview() {
  return StartupFailureShell(
    child: DatabaseFailureView(
      logFilePath: '/tmp/support/log.txt',
      detail: 'StateError: incompatible column',
      onSavePackage: (_) async => DeliveryOutcome.cancelled,
      onResetDatabase: () async => const ResetReport(),
    ),
  );
}
