import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/onboarding_feature/widgets/troubleshooting_wizard.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  Widget buildApp({required Widget child}) {
    return ShadApp(home: Scaffold(body: child));
  }

  group('TroubleshootingWizard', () {
    testWidgets('shows "machine powered on?" as first step', (tester) async {
      await tester.pumpWidget(
        buildApp(
          child: Builder(
            builder: (context) => ShadButton(
              onPressed: () => showTroubleshootingWizard(
                context: context,
                adapterState: AdapterState.poweredOn,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Is your machine powered on?'), findsOneWidget);
      expect(find.text("Yes, it's on"), findsOneWidget);
    });

    testWidgets(
      'advances to "other apps" step after confirming machine is on (non-iOS)',
      (tester) async {
        await tester.pumpWidget(
          buildApp(
            child: Builder(
              builder: (context) => ShadButton(
                onPressed: () => showTroubleshootingWizard(
                  context: context,
                  adapterState: AdapterState.poweredOn,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('Open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        await tester.tap(find.text("Yes, it's on"));
        await tester.pump();

        expect(find.text('Is another app connected?'), findsOneWidget);
        expect(find.text("I've closed other apps"), findsOneWidget);
      },
    );

    testWidgets('skips Bluetooth step on non-iOS', (tester) async {
      await tester.pumpWidget(
        buildApp(
          child: Builder(
            builder: (context) => ShadButton(
              onPressed: () => showTroubleshootingWizard(
                context: context,
                adapterState: AdapterState.poweredOff,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Is your machine powered on?'), findsOneWidget);

      await tester.tap(find.text("Yes, it's on"));
      await tester.pump();

      expect(find.text('Is Bluetooth enabled?'), findsNothing);
      expect(find.text('Is another app connected?'), findsOneWidget);
    });

    testWidgets('dismisses dialog on final step confirmation', (tester) async {
      await tester.pumpWidget(
        buildApp(
          child: Builder(
            builder: (context) => ShadButton(
              onPressed: () => showTroubleshootingWizard(
                context: context,
                adapterState: AdapterState.poweredOn,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text("Yes, it's on"));
      await tester.pump();

      expect(find.text('Is another app connected?'), findsOneWidget);
      await tester.tap(find.text("I've closed other apps"));
      await tester.pump();

      if (find.text("I've checked").evaluate().isNotEmpty) {
        await tester.tap(find.text("I've checked"));
        await tester.pump();
      }

      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Is your machine powered on?'), findsNothing);
      expect(find.text('Is another app connected?'), findsNothing);
      expect(find.text('Check System Bluetooth Settings'), findsNothing);
    });

    group('step shouldShow logic', () {
      test('bluetooth step shouldShow returns false on non-iOS', () {
        final steps = troubleshootingSteps(
          adapterState: AdapterState.poweredOff,
          isIOS: false,
        );
        final btStep = steps.firstWhere((s) => s.id == 'bluetooth');
        expect(btStep.shouldShow(), isFalse);
      });

      test(
        'bluetooth step shouldShow returns true on iOS with adapter not powered on',
        () {
          final steps = troubleshootingSteps(
            adapterState: AdapterState.poweredOff,
            isIOS: true,
          );
          final btStep = steps.firstWhere((s) => s.id == 'bluetooth');
          expect(btStep.shouldShow(), isTrue);
        },
      );

      test(
        'bluetooth step shouldShow returns false on iOS with adapter powered on',
        () {
          final steps = troubleshootingSteps(
            adapterState: AdapterState.poweredOn,
            isIOS: true,
          );
          final btStep = steps.firstWhere((s) => s.id == 'bluetooth');
          expect(btStep.shouldShow(), isFalse);
        },
      );

      test('system_bt step shouldShow returns true on macOS', () {
        final steps = troubleshootingSteps(
          adapterState: AdapterState.poweredOn,
          isMacOS: true,
        );
        final sysBtStep = steps.firstWhere((s) => s.id == 'system_bt');
        expect(sysBtStep.shouldShow(), isTrue);
      });

      test('system_bt step shouldShow returns false on non-macOS', () {
        final steps = troubleshootingSteps(
          adapterState: AdapterState.poweredOn,
          isMacOS: false,
        );
        final sysBtStep = steps.firstWhere((s) => s.id == 'system_bt');
        expect(sysBtStep.shouldShow(), isFalse);
      });

      test('macOS flow skips bluetooth step, includes system_bt', () {
        final steps = troubleshootingSteps(
          adapterState: AdapterState.poweredOff,
          isIOS: false,
          isMacOS: true,
        );
        final visibleIds = steps.where((s) => s.shouldShow()).map((s) => s.id);
        expect(visibleIds, ['machine_power', 'other_apps', 'system_bt']);
      });

      test('non-macOS/non-iOS flow excludes bluetooth and system_bt', () {
        final steps = troubleshootingSteps(
          adapterState: AdapterState.poweredOn,
          isIOS: false,
          isMacOS: false,
        );
        final visibleIds = steps.where((s) => s.shouldShow()).map((s) => s.id);
        expect(visibleIds, ['machine_power', 'other_apps']);
      });

      test(
        'bluetooth step shouldShow returns true on iOS with unauthorized state',
        () {
          final steps = troubleshootingSteps(
            adapterState: AdapterState.unauthorized,
            isIOS: true,
          );
          final btStep = steps.firstWhere((s) => s.id == 'bluetooth');
          expect(btStep.shouldShow(), isTrue);
        },
      );

      test('bluetooth step shows permission title when unauthorized', () {
        final steps = troubleshootingSteps(
          adapterState: AdapterState.unauthorized,
          isIOS: true,
        );
        final btStep = steps.firstWhere((s) => s.id == 'bluetooth');
        expect(btStep.title, 'Bluetooth Permission Required');
      });

      test('bluetooth step shows permission description when unauthorized', () {
        final steps = troubleshootingSteps(
          adapterState: AdapterState.unauthorized,
          isIOS: true,
        );
        final btStep = steps.firstWhere((s) => s.id == 'bluetooth');
        expect(
          btStep.description,
          contains('Settings > Privacy & Security > Bluetooth'),
        );
      });

      test(
        'bluetooth step shows generic title when adapter is not unauthorized',
        () {
          final steps = troubleshootingSteps(
            adapterState: AdapterState.poweredOff,
            isIOS: true,
          );
          final btStep = steps.firstWhere((s) => s.id == 'bluetooth');
          expect(btStep.title, 'Is Bluetooth enabled?');
        },
      );
    });

    testWidgets('shows description text for machine step', (tester) async {
      await tester.pumpWidget(
        buildApp(
          child: Builder(
            builder: (context) => ShadButton(
              onPressed: () => showTroubleshootingWizard(
                context: context,
                adapterState: AdapterState.poweredOn,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text(
          'Make sure your Decent Espresso machine is turned on and has finished its startup sequence.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows description text for other apps step', (tester) async {
      await tester.pumpWidget(
        buildApp(
          child: Builder(
            builder: (context) => ShadButton(
              onPressed: () => showTroubleshootingWizard(
                context: context,
                adapterState: AdapterState.poweredOn,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text("Yes, it's on"));
      await tester.pump();

      expect(
        find.text(
          'Only one app can connect to your machine via Bluetooth at a time. Close any other Decent apps (e.g., the original Decent app) and try again.',
        ),
        findsOneWidget,
      );
    });
  });
}
