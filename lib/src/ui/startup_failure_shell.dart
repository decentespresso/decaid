import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:reaprime/src/theme/theme.dart';

class StartupFailureShell extends StatelessWidget {
  const StartupFailureShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      title: 'Decaid',
      debugShowCheckedModeBanner: false,
      theme: buildDecentTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: ThemeMode.system,
      home: child,
    );
  }

  ShadThemeData _buildDarkTheme() {
    final theme = ShadThemeData(
      brightness: Brightness.dark,
      colorScheme: const DecentColorScheme.dark(
        destructive: Color(0xFFFFB4AB),
        primaryForeground: DecentColors.dark,
      ),
    );
    return theme.copyWith(
      destructiveAlertTheme: theme.destructiveAlertTheme.copyWith(
        descriptionStyle: theme.destructiveAlertTheme.descriptionStyle
            ?.copyWith(color: DecentColors.offWhite),
      ),
      outlineButtonTheme: theme.outlineButtonTheme.copyWith(
        foregroundColor: DecentColors.offWhite,
        hoverForegroundColor: DecentColors.dark,
        decoration: theme.outlineButtonTheme.decoration?.copyWith(
          border: ShadBorder.all(
            color: DecentColors.darkMutedForeground,
            radius: theme.radius,
            width: 1,
          ),
        ),
      ),
    );
  }
}
