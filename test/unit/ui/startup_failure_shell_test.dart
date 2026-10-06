import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/database_failure_view.dart';
import 'package:reaprime/src/services/export/archive_export.dart';
import 'package:reaprime/src/services/storage/database_recovery.dart';
import 'package:reaprime/src/theme/theme.dart';
import 'package:reaprime/src/ui/webserver_port_conflict_app.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('startup colours in ${brightness.name} mode', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final dark = brightness == Brightness.dark;

      Color? textColor(String text) => tester
          .widget<RichText>(
            find.descendant(
              of: find.text(text),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style
          ?.color;

      await tester.pumpWidget(const WebServerPortConflictApp(port: 8080));
      await tester.pumpAndSettle();
      final theme = ShadTheme.of(tester.element(find.byType(Scaffold)));
      expect(
        theme.colorScheme.background,
        dark ? DecentColors.bannerBg : DecentColors.white,
      );
      expect(theme.colorScheme.primary, DecentColors.teal);
      expect(
        textColor('Another Decaid app is running'),
        dark ? const Color(0xFFFFB4AB) : DecentColors.destructive,
      );
      expect(
        textColor('Close the other Decaid app, then open this one again.'),
        dark ? DecentColors.offWhite : DecentColors.destructive,
      );
      expect(
        textColor('Check again'),
        dark ? DecentColors.dark : DecentColors.white,
      );
      expect(
        textColor('Close this app'),
        dark ? DecentColors.offWhite : DecentColors.teal,
      );
      expect(
        theme.destructiveAlertTheme.iconColor,
        dark ? const Color(0xFFFFB4AB) : DecentColors.destructive,
      );
      expect(
        theme.destructiveAlertTheme.decoration?.border?.top?.color,
        dark ? const Color(0xFFFFB4AB) : DecentColors.destructive,
      );
      expect(
        theme.outlineButtonTheme.decoration?.border?.top?.color,
        dark ? DecentColors.darkMutedForeground : DecentColors.border,
      );
      if (dark) {
        expect(
          theme.primaryButtonTheme.hoverForegroundColor,
          DecentColors.dark,
        );
        expect(
          theme.outlineButtonTheme.hoverForegroundColor,
          DecentColors.dark,
        );
      }

      await tester.pumpWidget(
        DatabaseFailureApp(
          logFilePath: '/tmp/log.txt',
          detail: 'StateError',
          onSavePackage: (_) async => DeliveryOutcome.cancelled,
          onResetDatabase: () async => const ResetReport(),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        textColor('Diagnostic: StateError'),
        dark ? DecentColors.offWhite : DecentColors.destructive,
      );
      expect(
        textColor('Log file: /tmp/log.txt'),
        dark ? DecentColors.offWhite : DecentColors.destructive,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
