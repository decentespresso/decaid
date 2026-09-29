import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/feedback_feature/feedback_view.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _AccountService extends Fake implements DecentAccountService {
  DecentAccountStatus status = DecentAccountStatus.authenticated;
  int verificationCount = 0;

  @override
  Future<DecentAccountStatus> verifyStoredCredentialsStatus() async {
    verificationCount++;
    return status;
  }

  @override
  Future<bool> hasLinkedAccount() async => false;
}

void main() {
  testWidgets('discloses that only the support message ID is public', (
    tester,
  ) async {
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: FeedbackDialog(
            githubToken: '',
            serialNumbers: () => const [],
            accountService: null,
          ),
        ),
      ),
    );

    expect(find.textContaining('Only the support message ID'), findsOneWidget);
    expect(find.textContaining('added to the public issue'), findsOneWidget);
  });

  testWidgets('signed out feedback explains where to sign in', (tester) async {
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: FeedbackDialog(
            githubToken: 'test-token',
            serialNumbers: () => const [],
            accountService: null,
          ),
        ),
      ),
    );
    expect(find.textContaining('Sign in under Decent Account'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'Test report');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'You must be logged in to your Decent account to submit feedback.',
      ),
      findsOneWidget,
    );
    expect(find.text('Feedback submitted!'), findsNothing);
  });

  for (final authenticated in [true, false]) {
    testWidgets('Submit rechecks authentication: $authenticated', (
      tester,
    ) async {
      final account = _AccountService();
      final requests = <http.Request>[];
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            ShadApp(
              home: Scaffold(
                body: FeedbackDialog(
                  githubToken: 'test-token',
                  serialNumbers: () => const [],
                  accountService: account,
                ),
              ),
            ),
          );
          await tester.enterText(find.byType(EditableText), 'Test report');
          await tester.tap(find.text('Include application logs'));
          account.status = authenticated
              ? DecentAccountStatus.authenticated
              : DecentAccountStatus.unauthenticated;
          await tester.tap(find.text('Submit'));
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'number': 123,
              'html_url': 'https://github.com/example/issues/123',
            }),
            201,
          );
        }),
      );
      expect(account.verificationCount, 1);
      expect(requests, hasLength(authenticated ? 1 : 0));
      expect(
        find.text('Feedback submitted!'),
        authenticated ? findsOneWidget : findsNothing,
      );
    });
  }
}
