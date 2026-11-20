import 'package:flutter/material.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const appLogUploadLabel = 'Share app logs with Decent Support';
const appLogUploadCopy =
    'Sends app logs from the previous 24 hours, then hourly, to help us fix '
    'problems and improve our machines. Includes your machine\'s serial '
    'number, model, voltage setting, and warm-up times.';

class AppLogUploadSection extends StatelessWidget {
  const AppLogUploadSection({super.key, required this.service});

  final AppLogUploadService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final canUpload = service.enabled && !service.uploading;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Support logs',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            ShadSwitch(
              key: const Key('app-log-upload-toggle'),
              value: service.enabled,
              onChanged: service.setEnabled,
              label: const Text(appLogUploadLabel),
              sublabel: const Text(appLogUploadCopy),
            ),
            const SizedBox(height: 16),
            ShadButton.outline(
              key: const Key('app-log-upload-now'),
              enabled: canUpload,
              onPressed: canUpload ? service.uploadNow : null,
              leading: service.uploading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(LucideIcons.upload, size: 16),
              child: Text(service.uploading ? 'Uploading' : 'Upload now'),
            ),
            if (service.lastResult != null) ...[
              const SizedBox(height: 12),
              Text(
                service.lastResult!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        );
      },
    );
  }
}
