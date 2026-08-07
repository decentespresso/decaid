import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/presence_settings_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

void main() {
  late MockSettingsService mockService;
  late SettingsController controller;

  Widget buildPage() {
    return MaterialApp(
      home: ShadApp(home: PresenceSettingsPage(controller: controller)),
    );
  }

  setUp(() async {
    mockService = MockSettingsService();
    controller = SettingsController(mockService);
    await controller.loadSettings();
  });

  /// Returns the text inside the sleep-timeout [TextFormField].
  String sleepTimeoutFieldText(WidgetTester tester) {
    final field = find.byType(TextFormField).first;
    return tester.widget<TextFormField>(field).controller!.text;
  }

  group('sleep timeout text field', () {
    testWidgets('enters an in-range value and commits it', (tester) async {
      await tester.pumpWidget(buildPage());
      await tester.pump();

      final field = find.byType(TextFormField).first;
      await tester.enterText(field, '37');
      await tester.tap(find.text('Set'));
      await tester.pump();

      expect(controller.sleepTimeoutMinutes, 37);
      expect(sleepTimeoutFieldText(tester), '37');
    });

    testWidgets('clamps to 240', (tester) async {
      await tester.pumpWidget(buildPage());
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, '999');
      await tester.tap(find.text('Set'));
      await tester.pump();

      expect(controller.sleepTimeoutMinutes, 240);
      expect(sleepTimeoutFieldText(tester), '240');
    });

    testWidgets('clamps to 0 for negative input', (tester) async {
      await tester.pumpWidget(buildPage());
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, '-10');
      await tester.tap(find.text('Set'));
      await tester.pump();

      expect(controller.sleepTimeoutMinutes, 0);
      expect(sleepTimeoutFieldText(tester), '0');
    });

    testWidgets('empty text shows validation and does not persist', (
      tester,
    ) async {
      await tester.pumpWidget(buildPage());
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, '');
      await tester.tap(find.text('Set'));
      await tester.pump();

      expect(find.text('Enter a number of minutes'), findsOneWidget);
      expect(controller.sleepTimeoutMinutes, 30);
    });

    testWidgets('non-numeric text shows validation and does not persist', (
      tester,
    ) async {
      await tester.pumpWidget(buildPage());
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, 'abc');
      await tester.tap(find.text('Set'));
      await tester.pump();

      expect(find.text('Enter a number of minutes'), findsOneWidget);
      expect(controller.sleepTimeoutMinutes, 30);
    });

    testWidgets('arbitrary value like 37 is supported', (tester) async {
      await tester.pumpWidget(buildPage());
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, '37');
      await tester.tap(find.text('Set'));
      await tester.pump();

      expect(controller.sleepTimeoutMinutes, 37);
      expect(sleepTimeoutFieldText(tester), '37');
    });
  });

  group('rebuild safety', () {
    testWidgets('uncommitted text survives controller notification', (
      tester,
    ) async {
      await tester.pumpWidget(buildPage());
      await tester.pump();

      await tester.enterText(find.byType(TextFormField).first, '37');
      // do not commit — rebuild by changing an unrelated setting
      controller.setShowSkinExitInstructions(true);
      await tester.pump();

      expect(sleepTimeoutFieldText(tester), '37');
      expect(controller.sleepTimeoutMinutes, 30);
    });

    testWidgets('external change syncs field when unfocused', (tester) async {
      await tester.pumpWidget(buildPage());
      await tester.pump();

      expect(sleepTimeoutFieldText(tester), '30');

      await controller.setSleepTimeoutMinutes(90);
      await tester.pump();

      expect(sleepTimeoutFieldText(tester), '90');
    });

    testWidgets('focused field ignores external changes', (tester) async {
      await tester.pumpWidget(buildPage());
      await tester.pump();

      final field = find.byType(TextFormField).first;
      await tester.enterText(field, '42');

      await controller.setSleepTimeoutMinutes(90);
      await tester.pump();

      expect(sleepTimeoutFieldText(tester), '42');
    });
  });
}
