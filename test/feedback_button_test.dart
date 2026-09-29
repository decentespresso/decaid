import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/feedback_feature/feedback_button.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _Account extends Fake implements DecentAccountService {
  final changes = StreamController<void>.broadcast();
  Future<bool> status = Future.value(false);

  @override
  Stream<void> get identityAuthorityChanges => changes.stream;

  @override
  Future<bool> isLoggedIn() => status;
}

void main() {
  testWidgets('feedback is unavailable until logged in and hides on logout', (
    tester,
  ) async {
    final account = _Account();
    addTearDown(account.changes.close);
    var opened = false;
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: FeedbackButton(
            accountService: account,
            onPressed: () => opened = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Send Feedback'), findsNothing);
    expect(find.textContaining('Sign in under Decent Account'), findsOneWidget);

    account.status = Future.value(true);
    account.changes.add(null);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send Feedback'));
    expect(opened, isTrue);

    account.status = Future.value(false);
    account.changes.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Send Feedback'), findsNothing);
  });

  testWidgets('missing account and verification errors fail closed', (
    tester,
  ) async {
    final account = _Account();
    addTearDown(account.changes.close);
    for (final service in [null, account]) {
      final status = Completer<bool>();
      account.status = status.future;
      await tester.pumpWidget(
        ShadApp(
          home: Scaffold(
            body: FeedbackButton(
              accountService: service,
              onPressed: () => fail('must not open feedback'),
            ),
          ),
        ),
      );
      expect(find.text('Send Feedback'), findsNothing);
      if (service != null) status.completeError(StateError('unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('Send Feedback'), findsNothing);
    }
  });
}
