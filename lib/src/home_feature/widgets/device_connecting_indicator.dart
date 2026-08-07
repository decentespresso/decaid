import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DeviceConnectingIndicator extends StatelessWidget {
  final bool isConnecting;

  const DeviceConnectingIndicator({super.key, required this.isConnecting});

  @override
  Widget build(BuildContext context) {
    if (isConnecting) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    return const Icon(LucideIcons.chevronRight);
  }
}
