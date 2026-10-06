import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/database_failure_view.dart';
import 'package:reaprime/src/services/export/archive_export.dart';
import 'package:reaprime/src/services/storage/database_recovery.dart';
import 'package:reaprime/src/theme/theme.dart';
import 'package:reaprime/src/ui/startup_failure_shell.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

Widget host(Widget child) => StartupFailureShell(child: child);

DatabaseFailureView view({
  Future<DeliveryOutcome> Function(Rect)? onSave,
  Future<ResetReport> Function()? onReset,
}) {
  return DatabaseFailureView(
    logFilePath: '/tmp/support/log.txt',
    detail: 'StateError: incompatible column',
    onSavePackage: onSave ?? (_) async => DeliveryOutcome.cancelled,
    onResetDatabase: onReset ?? () async => const ResetReport(),
  );
}

void main() {
  testWidgets('explains the database could not be opened and data was kept', (
    tester,
  ) async {
    await tester.pumpWidget(host(view()));

    expect(find.textContaining('could not be safely opened'), findsOneWidget);
    expect(find.textContaining('left in place'), findsOneWidget);
    expect(
      find.textContaining('StateError: incompatible column'),
      findsOneWidget,
    );
    expect(find.textContaining('/tmp/support/log.txt'), findsOneWidget);
  });

  testWidgets('offers save and confirmed destructive reset actions', (
    tester,
  ) async {
    await tester.pumpWidget(host(view()));

    expect(find.byType(ShadButton), findsNWidgets(2));
    expect(find.text('Save recovery package'), findsOneWidget);
    expect(find.text('Reset local database'), findsOneWidget);
  });

  testWidgets('saving shows success and reset confirmation', (tester) async {
    var saves = 0;
    var resets = 0;
    await tester.pumpWidget(
      host(
        view(
          onSave: (_) async {
            saves++;
            return DeliveryOutcome.saved;
          },
          onReset: () async {
            resets++;
            return const ResetReport();
          },
        ),
      ),
    );

    await tester.tap(find.text('Save recovery package'));
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.text('Recovery package saved.'), findsOneWidget);

    await tester.tap(find.text('Reset local database'));
    await tester.pumpAndSettle();
    expect(resets, 0);
    expect(
      find.textContaining('No recovery package has been saved'),
      findsNothing,
    );
    expect(find.text('Reset local database'), findsNWidgets(2));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(resets, 0);
  });

  testWidgets('reset warns before a save and calls back only on confirmation', (
    tester,
  ) async {
    var resets = 0;
    await tester.pumpWidget(
      host(
        view(
          onReset: () async {
            resets++;
            return const ResetReport();
          },
        ),
      ),
    );

    await tester.tap(find.text('Reset local database'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('No recovery package has been saved'),
      findsOneWidget,
    );
    expect(find.text('Reset without a saved copy'), findsOneWidget);
    expect(resets, 0);
    await tester.tap(find.text('Reset without a saved copy'));
    await tester.pumpAndSettle();
    expect(resets, 1);
    expect(find.text('Data cleared. Close and reopen Decaid.'), findsOneWidget);
  });

  testWidgets('save failure shows status and re-enables both buttons', (
    tester,
  ) async {
    final error = StateError('disk full');
    await tester.pumpWidget(host(view(onSave: (_) async => throw error)));

    await tester.tap(find.text('Save recovery package'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not save the recovery package: $error'),
      findsOneWidget,
    );
    expect(
      tester.widget<ShadButton>(find.byType(ShadButton).at(0)).enabled,
      isTrue,
    );
    expect(
      tester.widget<ShadButton>(find.byType(ShadButton).at(1)).enabled,
      isTrue,
    );
  });

  testWidgets('partial reset reports failure instead of success', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        view(
          onReset: () async => const ResetReport(
            renameFailures: ['/db/streamline_bridge.sqlite'],
            leftovers: ['/db/store.reset-1'],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Reset local database'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset without a saved copy'));
    await tester.pumpAndSettle();

    expect(find.text('Data cleared. Close and reopen Decaid.'), findsNothing);
    expect(find.textContaining('/db/streamline_bridge.sqlite'), findsOneWidget);
    expect(find.textContaining('/db/store.reset-1'), findsOneWidget);
  });

  testWidgets('save cannot start while the reset dialog is open', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      host(
        view(
          onSave: (_) async {
            saves++;
            return DeliveryOutcome.cancelled;
          },
        ),
      ),
    );

    await tester.tap(find.text('Reset local database'));
    await tester.pumpAndSettle();

    final saveButton = tester.widget<ShadButton>(
      find.ancestor(
        of: find.text('Save recovery package'),
        matching: find.byType(ShadButton),
      ),
    );
    expect(saveButton.enabled, isFalse);
    expect(saves, 0);
  });

  testWidgets('both buttons are disabled during either operation', (
    tester,
  ) async {
    final completer = Completer<DeliveryOutcome>();
    await tester.pumpWidget(host(view(onSave: (_) => completer.future)));

    await tester.tap(find.text('Save recovery package'));
    await tester.pump();
    expect(
      tester
          .widgetList<ShadButton>(find.byType(ShadButton))
          .every((button) => !button.enabled),
      isTrue,
    );
    completer.complete(DeliveryOutcome.cancelled);
    await tester.pumpAndSettle();
  });

  testWidgets('DatabaseFailureApp renders a database-independent home', (
    tester,
  ) async {
    await tester.pumpWidget(
      DatabaseFailureApp(
        logFilePath: '/tmp/support/log.txt',
        onSavePackage: (_) async => DeliveryOutcome.cancelled,
        onResetDatabase: () async => const ResetReport(),
      ),
    );

    expect(find.byType(ShadApp), findsOneWidget);
    final context = tester.element(find.byType(DatabaseFailureView));
    expect(ShadTheme.of(context).colorScheme, isA<DecentColorScheme>());
    expect(find.textContaining('could not be safely opened'), findsOneWidget);
    expect(find.textContaining('left in place'), findsOneWidget);
  });

  testWidgets('all content is reachable on a compact screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const textScaler = TextScaler.linear(2);
    const viewPadding = EdgeInsets.all(24);
    await tester.pumpWidget(
      StartupFailureShell(
        child: MediaQuery(
          data: const MediaQueryData(
            textScaler: textScaler,
            padding: viewPadding,
          ),
          child: DatabaseFailureView(
            logFilePath: '/data/user/0/net.tadel.reaprime/files/logs/log.txt',
            detail: 'StateError',
            onSavePackage: (_) async => DeliveryOutcome.cancelled,
            onResetDatabase: () async => const ResetReport(),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('could not be safely opened'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('Save recovery package'), findsOneWidget);
    expect(find.text('Reset local database'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('assisted repair'),
      200,
      scrollable: find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.textContaining('assisted repair'), findsOneWidget);
    expect(find.textContaining('left in place'), findsOneWidget);
  });
}
