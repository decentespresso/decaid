import 'package:flutter/material.dart';
import 'package:reaprime/src/import/import_result.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ImportSummaryView extends StatelessWidget {
  final ScanResult scanResult;
  final VoidCallback onImportAll;
  final VoidCallback onCancel;

  const ImportSummaryView({
    super.key,
    required this.scanResult,
    required this.onImportAll,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ready to Import',
                style: theme.textTheme.h3,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Found in your Decent app folder:',
                style: theme.textTheme.muted,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ShadCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CountRow(
                      icon: LucideIcons.coffee,
                      label:
                          '${scanResult.shotCount} shot${scanResult.shotCount == 1 ? '' : 's'}',
                    ),
                    const SizedBox(height: 12),
                    _CountRow(
                      icon: LucideIcons.fileText,
                      label:
                          '${scanResult.profileCount} profile${scanResult.profileCount == 1 ? '' : 's'}',
                    ),
                    if (scanResult.hasDyeGrinders) ...[
                      const SizedBox(height: 12),
                      const _CountRow(
                        icon: LucideIcons.settings,
                        label: 'Grinder specs (DYE)',
                      ),
                    ],
                    if (scanResult.hasSettings) ...[
                      const SizedBox(height: 12),
                      const _CountRow(
                        icon: LucideIcons.settings2,
                        label: 'App settings',
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              AccessibleButton(
                label: 'Import All',
                onTap: onImportAll,
                child: ShadButton(
                  onPressed: onImportAll,
                  child: const Text('Import All'),
                ),
              ),
              const SizedBox(height: 8),
              AccessibleButton(
                label: 'Cancel',
                onTap: onCancel,
                child: ShadButton.outline(
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _CountRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return MergeSemantics(
      child: Row(
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: 18, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Text(label, style: theme.textTheme.p),
        ],
      ),
    );
  }
}
