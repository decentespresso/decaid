import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ConnectDeviceHeroCard extends StatelessWidget {
  const ConnectDeviceHeroCard({super.key, required this.onScan});

  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          Row(
            spacing: 8,
            children: [
              Icon(
                LucideIcons.bluetooth,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              Text('Connect your machine', style: theme.textTheme.h4),
            ],
          ),
          Text(
            'No machine connected. Scan to find and connect your '
            'Decent machine.',
            style: theme.textTheme.muted,
          ),
          ShadButton(
            size: ShadButtonSize.sm,
            leading: const Icon(LucideIcons.radar, size: 14),
            onPressed: onScan,
            child: const Text('Scan for devices'),
          ),
        ],
      ),
    );
  }
}

@Preview(name: 'Connect Device Hero Card', group: 'Launcher')
Widget connectDeviceHeroCardPreview() {
  return ShadApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: SizedBox(
          width: 500,
          child: ConnectDeviceHeroCard(onScan: () {}),
        ),
      ),
    ),
  );
}
