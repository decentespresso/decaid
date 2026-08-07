import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SkinUnavailableCard extends StatelessWidget {
  const SkinUnavailableCard({
    super.key,
    required this.reason,
    this.onPickSkin,
    this.onExportLogs,
    this.onSendFeedback,
  });

  final SkinUnavailableReason reason;
  final VoidCallback? onPickSkin;
  final VoidCallback? onExportLogs;
  final VoidCallback? onSendFeedback;

  @override
  Widget build(BuildContext context) {
    return ShadAlert(
      icon: const Icon(LucideIcons.info, size: 16),
      title: Text(_title),
      description: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text(_description),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (reason == SkinUnavailableReason.notServing &&
                  onPickSkin != null)
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  onPressed: onPickSkin,
                  child: const Text('Pick a skin'),
                ),
              if (onExportLogs != null)
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  onPressed: onExportLogs,
                  child: const Text('Export logs'),
                ),
              if (onSendFeedback != null)
                ShadButton.outline(
                  size: ShadButtonSize.sm,
                  onPressed: onSendFeedback,
                  child: const Text('Send feedback'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String get _title {
    switch (reason) {
      case SkinUnavailableReason.notServing:
        return 'WebUI is not running';
      case SkinUnavailableReason.noWebView:
        return 'WebView not available';
      case SkinUnavailableReason.skinError:
        return 'Skin failed to load';
    }
  }

  String get _description {
    switch (reason) {
      case SkinUnavailableReason.notServing:
        return 'No skin is currently serving. Pick a skin to get started, '
            'or use a browser to connect.';
      case SkinUnavailableReason.noWebView:
        return 'This platform does not support in-app WebView. '
            'Use a browser on another device to access the full UI.';
      case SkinUnavailableReason.skinError:
        return 'Something went wrong loading the skin. '
            'Try picking a different skin, or export logs for troubleshooting.';
    }
  }
}

enum SkinUnavailableReason { notServing, noWebView, skinError }

@Preview(name: 'Skin Unavailable - Not Serving', group: 'Launcher')
Widget skinUnavailableNotServingPreview() {
  return ShadApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: SizedBox(
          width: 500,
          child: SkinUnavailableCard(
            reason: SkinUnavailableReason.notServing,
            onPickSkin: () {},
            onExportLogs: () {},
            onSendFeedback: () {},
          ),
        ),
      ),
    ),
  );
}

@Preview(name: 'Skin Unavailable - No WebView', group: 'Launcher')
Widget skinUnavailableNoWebviewPreview() {
  return ShadApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: SizedBox(
          width: 500,
          child: SkinUnavailableCard(
            reason: SkinUnavailableReason.noWebView,
            onExportLogs: () {},
          ),
        ),
      ),
    ),
  );
}
