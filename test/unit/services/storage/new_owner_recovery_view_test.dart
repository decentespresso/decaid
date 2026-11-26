import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/new_owner_recovery_view.dart';
import 'package:reaprime/src/services/storage/new_owner_recovery_admission.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    NewOwnerRecoveryAdmission kind, {
    String? detail,
    String? logFilePath,
  }) async {
    await tester.pumpWidget(
      NewOwnerRecoveryApp(
        admission: NewOwnerRecoveryAdmissionDecision(kind, detail: detail),
        logFilePath: logFilePath,
      ),
    );
    await tester.pump();
  }

  group('recovery view', () {
    testWidgets('an incomplete reset explains the blocked state', (
      tester,
    ) async {
      await pump(tester, NewOwnerRecoveryAdmission.resetInProgress);

      expect(
        find.text('Preparing this Decaid for a new owner'),
        findsOneWidget,
      );
      expect(
        find.textContaining('has not started its normal services'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Do not clear app data or reinstall'),
        findsOneWidget,
      );
    });

    testWidgets('a ready journal is presented as a terminal state', (
      tester,
    ) async {
      await pump(tester, NewOwnerRecoveryAdmission.readyForNewOwner);

      expect(find.text('Prepared for a new owner'), findsOneWidget);
      expect(
        find.textContaining('has not started its normal services'),
        findsOneWidget,
      );
    });

    testWidgets('an armed handoff stays terminal for this process', (
      tester,
    ) async {
      await pump(tester, NewOwnerRecoveryAdmission.handoffArmedThisProcess);

      expect(find.text('Prepared for a new owner'), findsOneWidget);
      expect(find.textContaining('Close Decaid'), findsOneWidget);
    });

    testWidgets('an eligible handoff is not presented as admitted', (
      tester,
    ) async {
      await pump(tester, NewOwnerRecoveryAdmission.handoffEligible);

      expect(find.text('Ready to start for its new owner'), findsOneWidget);
      expect(
        find.textContaining('will not start the customer setup by itself'),
        findsOneWidget,
      );
    });

    testWidgets('an uncertain state shows the recovery error', (tester) async {
      await pump(
        tester,
        NewOwnerRecoveryAdmission.uncertain,
        detail: 'journal is unreadable',
      );

      expect(
        find.text('Decaid recovery state could not be read'),
        findsOneWidget,
      );
      expect(find.textContaining('journal is unreadable'), findsOneWidget);
    });

    testWidgets('the log path is offered without any reset action', (
      tester,
    ) async {
      await pump(
        tester,
        NewOwnerRecoveryAdmission.uncertain,
        logFilePath: '/tmp/support/log.txt',
      );

      expect(find.textContaining('/tmp/support/log.txt'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton || widget is MaterialButton,
        ),
        findsNothing,
      );
      expect(find.textContaining('Reset'), findsNothing);
      expect(find.textContaining('new owner setup'), findsNothing);
    });

    testWidgets('normal startup cannot be rendered as a blocked view', (
      tester,
    ) async {
      await tester.pumpWidget(
        const NewOwnerRecoveryApp(
          admission: NewOwnerRecoveryAdmissionDecision(
            NewOwnerRecoveryAdmission.normalStartup,
          ),
        ),
      );

      expect(tester.takeException(), isA<ArgumentError>());
    });
  });

  group('startup failure view', () {
    testWidgets('a startup failure renders without a log path', (tester) async {
      await tester.pumpWidget(
        const NewOwnerRecoveryStartupErrorApp(
          detail: 'the recovery directory could not be resolved',
        ),
      );
      await tester.pump();

      expect(find.text('Decaid could not start'), findsOneWidget);
      expect(
        find.textContaining('the recovery directory could not be resolved'),
        findsOneWidget,
      );
      expect(
        find.textContaining('stopped before starting its normal services'),
        findsOneWidget,
      );
      expect(find.textContaining('Log file:'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton || widget is MaterialButton,
        ),
        findsNothing,
      );
    });

    testWidgets('a startup failure offers the recovery log when one exists', (
      tester,
    ) async {
      await tester.pumpWidget(
        const NewOwnerRecoveryStartupErrorApp(
          detail: 'the log directory could not be created',
          logFilePath: '/support/logs/recovery-startup.log',
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('/support/logs/recovery-startup.log'),
        findsOneWidget,
      );
    });
  });
}
