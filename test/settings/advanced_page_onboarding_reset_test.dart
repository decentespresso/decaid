import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/advanced_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

const _tileKey = Key('advanced-reset-onboarding');
const _confirmKey = Key('advanced-reset-onboarding-confirm');
const _cancelKey = Key('advanced-reset-onboarding-cancel');

class _Harness {
  _Harness({required this.service, required this.controller});

  final MockSettingsService service;
  final SettingsController controller;
}

Future<_Harness> _pump(WidgetTester tester, {bool failWrite = false}) async {
  final service = MockSettingsService()..failOnboardingReplayWrite = failWrite;
  final controller = SettingsController(service);
  await controller.loadSettings();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ShadApp(
      home: ScaffoldMessenger(child: AdvancedPage(controller: controller)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.byKey(_tileKey), 200);
  await tester.pumpAndSettle();
  return _Harness(service: service, controller: controller);
}

void main() {
  testWidgets('the reset action sits near Exit Decaid and asks to confirm', (
    tester,
  ) async {
    final harness = await _pump(tester);

    expect(find.text('Reset onboarding'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(_tileKey)).dy,
      greaterThan(tester.getTopLeft(find.text('Exit Decaid')).dy),
    );

    await tester.tap(find.byKey(_tileKey));
    await tester.pumpAndSettle();

    expect(find.text('Reset onboarding?'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('next cold launch'),
      ),
      findsOneWidget,
      reason: 'the operator is told when the screens return',
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('kept'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(_cancelKey));
    await tester.pumpAndSettle();

    expect(find.text('Reset onboarding?'), findsNothing);
    expect(harness.service.onboardingReplayRequestWrites, 0);
    expect(harness.controller.onboardingCompleted, isTrue);
  });

  testWidgets('confirming arms the next cold launch and reports success', (
    tester,
  ) async {
    final harness = await _pump(tester);

    await tester.tap(find.byKey(_tileKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_confirmKey));
    await tester.pumpAndSettle();

    expect(await harness.service.onboardingReplayRequested(), isTrue);
    expect(harness.service.onboardingReplayRequestWrites, 1);
    expect(
      find.text('Setup screens will run on the next cold launch.'),
      findsOneWidget,
    );
    expect(
      harness.controller.onboardingCompleted,
      isTrue,
      reason: 'the running session keeps its state',
    );

    await tester.tap(find.byKey(_tileKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_confirmKey));
    await tester.pumpAndSettle();

    expect(harness.service.onboardingReplayRequestWrites, 2);
    expect(await harness.service.onboardingReplayRequested(), isTrue);
  });

  testWidgets('a failed save reports an error instead of success', (
    tester,
  ) async {
    final harness = await _pump(tester, failWrite: true);

    await tester.tap(find.byKey(_tileKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_confirmKey));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not save the onboarding reset. Try again.'),
      findsOneWidget,
    );
    expect(
      find.text('Setup screens will run on the next cold launch.'),
      findsNothing,
    );
    expect(await harness.service.onboardingReplayRequested(), isFalse);
    expect(harness.controller.onboardingCompleted, isTrue);
  });
}
