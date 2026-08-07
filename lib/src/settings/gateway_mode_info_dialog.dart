import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void showGatewayModeInfoDialog(BuildContext context) {
  showShadDialog(
    context: context,
    builder: (context) => ShadDialog(
      title: const Text('Gateway Mode'),
      description: const Text(
        'Control how external skins interact with the machine',
      ),
      actions: [
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 16,
        children: [
          _GatewayModeOption(
            title: 'Tracking',
            description:
                'External skins control the machine. This app adds weight tracking and stops the shot at your target. (Used by most skins.)',
            icon: Icons.track_changes,
            color: Colors.orange,
          ),
          _GatewayModeOption(
            title: 'Full',
            description:
                'External skins fully control the machine, including stopping the shot. This app only displays status.',
            icon: Icons.open_in_browser,
            color: Colors.blue,
          ),
          _GatewayModeOption(
            title: 'Disabled',
            description:
                'This app controls the machine directly. External skins can\'t. (Legacy.)',
            icon: Icons.block,
            color: Colors.grey,
          ),
          const SizedBox(height: 8),
          Builder(
            builder: (context) => Text(
              'Use gateway mode when you drive the machine from an external skin — a web dashboard, browser, or another tablet.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    ),
  );
}

class _GatewayModeOption extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final Color color;

  const _GatewayModeOption({
    required this.title,
    required this.description,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Icon(icon, size: 24, color: color),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              Text(description, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
