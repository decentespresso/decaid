import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../services/app_update_state.dart';
import '../services/update_check_service.dart';

class NotificationUpdateCheck extends StatelessWidget {
  const NotificationUpdateCheck({super.key, required this.service});

  final UpdateCheckService? service;

  @override
  Widget build(BuildContext context) => StreamBuilder<AppUpdateState>(
    stream: service?.updateState,
    initialData: service?.currentState,
    builder: (context, snapshot) {
      final busy = const {
        AppUpdatePhase.checking,
        AppUpdatePhase.downloading,
        AppUpdatePhase.installing,
      }.contains(snapshot.data?.phase);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (snapshot.data?.phase == AppUpdatePhase.error)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Could not check for updates. Please try again.'),
            ),
          ShadButton.outline(
            height: 0,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            enabled: service?.canCheck == true && !busy,
            onPressed: service?.requestCheck,
            leading: const Icon(LucideIcons.refreshCw, size: 16),
            child: Flexible(
              child: Text(busy ? 'Checking...' : 'Check for updates'),
            ),
          ),
        ],
      );
    },
  );
}
