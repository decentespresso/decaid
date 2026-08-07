import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:saf_util/saf_util.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ImportSourcePicker extends StatelessWidget {
  final void Function(String folderPath) onDe1appFolderSelected;
  final void Function(String filePath) onZipFileSelected;
  final VoidCallback? onSkip;

  const ImportSourcePicker({
    super.key,
    required this.onDe1appFolderSelected,
    required this.onZipFileSelected,
    this.onSkip,
  });

  Future<void> _pickFolder(BuildContext context) async {
    if (Platform.isAndroid) {
      final picked = await SafUtil().pickDirectory(
        writePermission: false,
        persistablePermission: false,
      );
      if (picked != null && context.mounted) {
        onDe1appFolderSelected(picked.uri);
      }
    } else {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select your de1plus folder',
      );
      if (path != null && context.mounted) {
        onDe1appFolderSelected(path);
      }
    }
  }

  Future<void> _pickZipFile(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      dialogTitle: 'Select a .zip backup file',
    );
    if (result != null &&
        result.files.isNotEmpty &&
        result.files.first.path != null &&
        context.mounted) {
      onZipFileSelected(result.files.first.path!);
    }
  }

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
                'Import Your Data',
                style: theme.textTheme.h3,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Bring your data from the Decent app or restore a Bridge backup.',
                style: theme.textTheme.muted,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              _SourceCard(
                icon: LucideIcons.folder,
                title: 'Import from Decent app',
                subtitle: 'Select your de1plus folder',
                onTap: () => _pickFolder(context),
              ),
              const SizedBox(height: 12),
              _SourceCard(
                icon: LucideIcons.archiveRestore,
                title: 'Import Bridge backup',
                subtitle: 'Select a .zip backup file',
                onTap: () => _pickZipFile(context),
              ),
              if (onSkip != null) ...[
                const SizedBox(height: 24),
                Center(
                  child: AccessibleButton(
                    label: 'Skip for now',
                    onTap: onSkip,
                    child: ShadButton.ghost(
                      onPressed: onSkip,
                      child: Text('Skip for now', style: theme.textTheme.muted),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SourceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadCard(
      padding: EdgeInsets.zero,
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.muted,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      icon,
                      size: 20,
                      color: theme.colorScheme.mutedForeground,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.p),
                      const SizedBox(height: 2),
                      Text(subtitle, style: theme.textTheme.muted),
                    ],
                  ),
                ),
                ExcludeSemantics(
                  child: Icon(
                    LucideIcons.chevronRight,
                    size: 16,
                    color: theme.colorScheme.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
