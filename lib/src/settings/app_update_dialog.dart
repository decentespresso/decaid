import 'package:flutter/material.dart';
import 'package:reaprime/build_info.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_state.dart';
import '../services/update_check_service.dart';
import 'update_dialog.dart';

Future<void> showAppUpdateDialog(
  BuildContext context,
  UpdateCheckService service,
) async {
  final update = service.availableUpdate;
  if (update == null || !context.mounted) return;
  void viewReleaseNotes() {
    final releaseUrl = service.getReleaseUrl();
    if (releaseUrl != null) launchUrl(Uri.parse(releaseUrl));
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => service.canInstall
        ? UpdateDialog(
            service: service,
            updateInfo: update,
            currentVersion: BuildInfo.version,
            onViewReleaseNotes: viewReleaseNotes,
          )
        : StreamBuilder<AppUpdateState>(
            stream: service.updateState,
            initialData: service.currentState,
            builder: (_, _) {
              final current = service.availableUpdate;
              return AlertDialog(
                title: const Text('Update Available'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (current == null)
                      const Text('This update is no longer available.')
                    else
                      Text('Version ${current.version} is available'),
                    const SizedBox(height: 8),
                    Text('Current version: ${BuildInfo.version}'),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Later'),
                  ),
                  if (current != null)
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        viewReleaseNotes();
                      },
                      child: const Text("What's new"),
                    ),
                ],
              );
            },
          ),
  );
}

class AppUpdatePrompt extends StatefulWidget {
  const AppUpdatePrompt({
    super.key,
    required this.service,
    required this.version,
    required this.child,
  });

  final UpdateCheckService service;
  final String version;
  final Widget child;

  @override
  State<AppUpdatePrompt> createState() => _AppUpdatePromptState();
}

class _AppUpdatePromptState extends State<AppUpdatePrompt> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final service = widget.service;
    if (service.availableUpdate?.version != widget.version) {
      await service.requestCheck();
      if (service.currentState.phase == AppUpdatePhase.checking) {
        await service.updateState.firstWhere(
          (state) => state.phase != AppUpdatePhase.checking,
        );
      }
    }
    if (!mounted) return;
    if (service.availableUpdate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            service.currentState.phase == AppUpdatePhase.error
                ? service.currentState.error ?? 'Could not check for updates'
                : 'You are on the latest version',
          ),
        ),
      );
      return;
    }
    await showAppUpdateDialog(context, service);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
