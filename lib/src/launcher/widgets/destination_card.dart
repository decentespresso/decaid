import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DestinationCard extends StatelessWidget {
  const DestinationCard({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: ShadCard(
        rowMainAxisAlignment: .center,
        columnMainAxisAlignment: .spaceBetween,
        padding: EdgeInsets.zero,
        backgroundColor: theme.colorScheme.secondary,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox.expand(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 12,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(icon, size: 32, color: theme.colorScheme.foreground),
                      if (badge != null)
                        Positioned(
                          right: -8,
                          top: -8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              badge!,
                              style: theme.textTheme.small.copyWith(
                                color: theme.colorScheme.primaryForeground,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Text(
                    label,
                    style: theme.textTheme.table.copyWith(
                      color: theme.colorScheme.foreground,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@Preview(name: 'Destination Card', group: 'Launcher')
Widget destinationCardPreview() {
  return ShadApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            SizedBox(
              width: 120,
              child: DestinationCard(
                icon: LucideIcons.settings,
                label: 'Settings',
                onTap: () {},
              ),
            ),
            SizedBox(
              width: 120,
              child: DestinationCard(
                icon: LucideIcons.database,
                label: 'Data',
                onTap: () {},
                badge: '3',
              ),
            ),
            SizedBox(
              width: 120,
              child: DestinationCard(
                icon: LucideIcons.bluetooth,
                label: 'Devices',
                onTap: () {},
              ),
            ),
            SizedBox(
              width: 120,
              child: DestinationCard(
                icon: LucideIcons.palette,
                label: 'Skins',
                onTap: () {},
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
