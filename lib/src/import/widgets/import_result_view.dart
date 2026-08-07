import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:reaprime/src/import/import_result.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:share_plus/share_plus.dart';

class ImportResultView extends StatefulWidget {
  final ImportResult result;
  final VoidCallback onContinue;

  const ImportResultView({
    super.key,
    required this.result,
    required this.onContinue,
  });

  @override
  State<ImportResultView> createState() => _ImportResultViewState();
}

class _ImportResultViewState extends State<ImportResultView> {
  bool _errorsExpanded = false;

  ImportResult get result => widget.result;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final hasErrors = result.hasErrors;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              Column(
                spacing: 8,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      hasErrors
                          ? LucideIcons.triangleAlert
                          : LucideIcons.circleCheck,
                      size: 48,
                      color: hasErrors
                          ? theme.colorScheme.destructive
                          : theme.colorScheme.primary,
                    ),
                  ),
                  Text(
                    hasErrors
                        ? 'Import Complete (with issues)'
                        : 'Import Complete',
                    style: theme.textTheme.h4,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),

              ShadCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    _ResultRow(
                      icon: LucideIcons.coffee,
                      label:
                          '${result.shotsImported} shot${result.shotsImported == 1 ? '' : 's'} imported',
                    ),
                    if (result.shotsSkipped > 0)
                      _ResultRow(
                        icon: LucideIcons.skipForward,
                        label:
                            '${result.shotsSkipped} shot${result.shotsSkipped == 1 ? '' : 's'} skipped',
                        muted: true,
                      ),
                    _ResultRow(
                      icon: LucideIcons.fileText,
                      label:
                          '${result.profilesImported} profile${result.profilesImported == 1 ? '' : 's'} imported',
                    ),
                    if (result.profilesSkipped > 0)
                      _ResultRow(
                        icon: LucideIcons.skipForward,
                        label:
                            '${result.profilesSkipped} profile${result.profilesSkipped == 1 ? '' : 's'} skipped',
                        muted: true,
                      ),
                    if (result.beansCreated > 0)
                      _ResultRow(
                        icon: LucideIcons.bean,
                        label:
                            '${result.beansCreated} coffee${result.beansCreated == 1 ? '' : 's'} added',
                      ),
                    if (result.beansSkipped > 0)
                      _ResultRow(
                        icon: LucideIcons.skipForward,
                        label:
                            '${result.beansSkipped} coffee${result.beansSkipped == 1 ? '' : 's'} skipped',
                        muted: true,
                      ),
                    if (result.grindersCreated > 0)
                      _ResultRow(
                        icon: LucideIcons.settings,
                        label:
                            '${result.grindersCreated} grinder${result.grindersCreated == 1 ? '' : 's'} added',
                      ),
                    if (result.grindersSkipped > 0)
                      _ResultRow(
                        icon: LucideIcons.skipForward,
                        label:
                            '${result.grindersSkipped} grinder${result.grindersSkipped == 1 ? '' : 's'} skipped',
                        muted: true,
                      ),
                    if (result.settingsApplied)
                      const _ResultRow(
                        icon: LucideIcons.settings2,
                        label: 'Settings applied',
                      ),
                    if (hasErrors)
                      _ResultRow(
                        icon: LucideIcons.circleX,
                        label:
                            '${result.errors.length} error${result.errors.length == 1 ? '' : 's'}',
                        destructive: true,
                      ),
                  ],
                ),
              ),

              if (hasErrors) ...[
                AccessibleButton(
                  label: _errorsExpanded ? 'Hide details' : 'Show details',
                  onTap: () {
                    setState(() {
                      _errorsExpanded = !_errorsExpanded;
                    });
                  },
                  child: ShadButton.outline(
                    onPressed: () {
                      setState(() {
                        _errorsExpanded = !_errorsExpanded;
                      });
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 6,
                      children: [
                        Icon(
                          _errorsExpanded
                              ? LucideIcons.chevronUp
                              : LucideIcons.chevronDown,
                          size: 14,
                        ),
                        Text(_errorsExpanded ? 'Hide details' : 'Show details'),
                      ],
                    ),
                  ),
                ),
                if (_errorsExpanded)
                  ShadCard(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 8,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              spacing: 6,
                              children: result.errors
                                  .map((e) => _ErrorItem(error: e))
                                  .toList(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        AccessibleButton(
                          label: 'Share Report',
                          onTap: _shareReport,
                          child: ShadButton.outline(
                            onPressed: _shareReport,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              spacing: 6,
                              children: const [
                                Icon(LucideIcons.share2, size: 14),
                                Text('Share Report'),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],

              AccessibleButton(
                label: 'Continue',
                onTap: widget.onContinue,
                child: ShadButton(
                  onPressed: widget.onContinue,
                  child: const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareReport() async {
    try {
      final report = _buildReportText();
      final tempDir = await getTemporaryDirectory();
      final reportFile = File('${tempDir.path}/import_report.txt');
      await reportFile.writeAsString(report);

      try {
        final docs = await getApplicationDocumentsDirectory();
        final logFile = File('${docs.path}/log.txt');
        if (await logFile.exists()) {
          final logContent = await logFile.readAsString();
          await reportFile.writeAsString(
            '\n\n--- App Logs ---\n$logContent',
            mode: FileMode.append,
          );
        }
      } catch (_) {}

      if (Platform.isAndroid || Platform.isIOS) {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(reportFile.path)]),
        );
      } else {
        final bytes = await reportFile.readAsBytes();
        await FilePicker.saveFile(
          fileName: 'import_report.txt',
          dialogTitle: 'Save Import Report',
          bytes: bytes,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to share report: $e')));
      }
    }
  }

  String _buildReportText() {
    final buf = StringBuffer();
    buf.writeln('Import Report');
    buf.writeln('=============');
    buf.writeln('Date: ${DateTime.now().toIso8601String()}');
    buf.writeln('Platform: ${Platform.operatingSystem}');
    buf.writeln();
    buf.writeln('Results:');
    buf.writeln('  Shots imported:    ${result.shotsImported}');
    buf.writeln('  Shots skipped:     ${result.shotsSkipped}');
    buf.writeln('  Profiles imported: ${result.profilesImported}');
    buf.writeln('  Profiles skipped:  ${result.profilesSkipped}');
    buf.writeln('  Beans created:     ${result.beansCreated}');
    buf.writeln('  Beans skipped:     ${result.beansSkipped}');
    buf.writeln('  Grinders created:  ${result.grindersCreated}');
    buf.writeln('  Grinders skipped:  ${result.grindersSkipped}');
    buf.writeln(
      '  Settings applied:  ${result.settingsApplied ? 'yes' : 'no'}',
    );
    buf.writeln('  Errors:            ${result.errors.length}');
    if (result.errors.isNotEmpty) {
      buf.writeln();
      buf.writeln('Error Details:');
      for (final e in result.errors) {
        buf.writeln('  - ${e.filename}: ${e.reason}');
        if (e.details != null) {
          buf.writeln('    ${e.details}');
        }
      }
    }
    return buf.toString();
  }
}

class _ResultRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool muted;
  final bool destructive;

  const _ResultRow({
    required this.icon,
    required this.label,
    this.muted = false,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final color = destructive
        ? theme.colorScheme.destructive
        : muted
        ? theme.colorScheme.mutedForeground
        : null;
    final style = muted || destructive
        ? theme.textTheme.muted
        : theme.textTheme.p;
    final effectiveStyle = color != null ? style.copyWith(color: color) : style;

    return MergeSemantics(
      child: Row(
        spacing: 8,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 16, color: color)),
          Text(label, style: effectiveStyle),
        ],
      ),
    );
  }
}

class _ErrorItem extends StatelessWidget {
  final ImportError error;

  const _ErrorItem({required this.error});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        Text(error.filename, style: theme.textTheme.small),
        Text(error.reason, style: theme.textTheme.muted),
      ],
    );
  }
}
