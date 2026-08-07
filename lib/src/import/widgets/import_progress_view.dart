import 'package:flutter/material.dart';
import 'package:reaprime/src/import/import_result.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ImportProgressView extends StatelessWidget {
  final ImportProgress progress;
  final int shotsImported;
  final int profilesImported;
  final int beansCreated;
  final int grindersCreated;

  const ImportProgressView({
    super.key,
    required this.progress,
    required this.shotsImported,
    required this.profilesImported,
    this.beansCreated = 0,
    this.grindersCreated = 0,
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
            children: [
              ExcludeSemantics(
                child: Icon(
                  LucideIcons.download,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Importing Your Data...',
                style: theme.textTheme.h3,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              Semantics(
                label: 'Import progress',
                child: ShadProgress(value: progress.fraction),
              ),
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  '${progress.current} of ${progress.total} ${progress.phase}',
                  style: theme.textTheme.muted,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 16),
              if (shotsImported > 0)
                Text(
                  '$shotsImported shot${shotsImported == 1 ? '' : 's'} processed',
                  style: theme.textTheme.muted,
                ),
              if (profilesImported > 0)
                Text(
                  '$profilesImported profile${profilesImported == 1 ? '' : 's'} imported',
                  style: theme.textTheme.muted,
                ),
              if (beansCreated > 0)
                Text(
                  '$beansCreated coffee${beansCreated == 1 ? '' : 's'} added',
                  style: theme.textTheme.muted,
                ),
              if (grindersCreated > 0)
                Text(
                  '$grindersCreated grinder${grindersCreated == 1 ? '' : 's'} added',
                  style: theme.textTheme.muted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
