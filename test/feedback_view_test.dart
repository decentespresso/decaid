import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/feedback_feature/feedback_view.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _GithubStore implements CredentialStore {
  String? value;

  @override
  Future<String?> read({required String key}) async => value;

  @override
  Future<void> write({required String key, required String value}) async {
    this.value = value;
  }

  @override
  Future<void> delete({required String key}) async {
    value = null;
  }
}

class _WarningAccountService extends _AccountService {
  @override
  Future<bool> hasLinkedAccount() async => true;

  @override
  Future<SupportMessageReceipt> sendSupportMessage({
    required String subject,
    required String body,
    Future<void>? abortTrigger,
  }) async {
    throw StateError('support unavailable');
  }
}

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
  testWidgets('offline feedback retains its text and offers manual Retry', (
    tester,
  ) async {
    var requests = 0;
    final account = _AccountService();
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
        await tester.enterText(find.byType(EditableText), 'Keep this report');
        await tester.tap(find.text('Include application logs'));
        await tester.tap(find.text('Submit'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            "Couldn't send feedback. Check your internet connection and try again.",
          ),
          findsOneWidget,
        );
        expect(find.text('Keep this report'), findsOneWidget);
        expect(requests, 1);
        expect(find.text('Retry'), findsOneWidget);
      },
      () => MockClient((_) async {
        requests++;
        throw const SocketException('private host lookup');
      }),
    );
  });

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

  testWidgets('native feedback uses live user PAT and bundled fallback', (
    tester,
  ) async {
    final account = _AccountService();
    final credentials = GithubCredentialProvider(store: _GithubStore());
    final requests = <http.Request>[];
    var generation = 0;

    await http.runWithClient(
      () async {
        Future<void> submit() async {
          await tester.enterText(find.byType(EditableText), 'Native report');
          await tester.tap(find.text('Include application logs'));
          await tester.tap(find.text('Submit'));
          await tester.pumpAndSettle();
          expect(find.text('Feedback submitted!'), findsOneWidget);
        }

        Future<void> showDialog() async {
          await tester.pumpWidget(
            ShadApp(
              home: Scaffold(
                body: FeedbackDialog(
                  key: ValueKey(generation++),
                  githubToken: 'bundled-pat',
                  serialNumbers: () => const [],
                  accountService: account,
                  credentials: credentials,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await showDialog();
        await submit();
        await credentials.save('user-pat');
        await showDialog();
        await submit();
        await credentials.remove();
        await showDialog();
        await submit();
      },
      () => MockClient((request) async {
        requests.add(request);
        final number = requests
            .where((request) => request.url.path.endsWith('/issues'))
            .length;
        return http.Response(
          jsonEncode({
            'number': number,
            'html_url':
                'https://github.com/decentespresso/decaid/issues/$number',
          }),
          201,
        );
      }),
    );

    expect(
      requests
          .where((request) => request.url.path.endsWith('/issues'))
          .map((request) => request.headers['authorization']),
      ['Bearer bundled-pat', 'Bearer user-pat', 'Bearer bundled-pat'],
    );
  });

  testWidgets('created issue support warning offers only View and Done', (
    tester,
  ) async {
    final requests = <http.Request>[];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          ShadApp(
            home: Scaffold(
              body: FeedbackDialog(
                githubToken: 'bundled-pat',
                serialNumbers: () => const [],
                accountService: _WarningAccountService(),
              ),
            ),
          ),
        );
        await tester.enterText(find.byType(EditableText), 'Native report');
        await tester.tap(find.text('Include application logs'));
        await tester.tap(find.text('Submit'));
        await tester.pumpAndSettle();

        expect(find.text('Feedback submitted!'), findsOneWidget);
        expect(find.textContaining('Decent Support linking'), findsOneWidget);
        expect(find.text('View on GitHub'), findsOneWidget);
        expect(find.text('Done'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
        expect(find.text('Submit'), findsNothing);
        expect(find.text('Resubmit'), findsNothing);
      },
      () => MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'number': 123,
            'html_url': 'https://github.com/decentespresso/decaid/issues/123',
          }),
          201,
        );
      }),
    );
    expect(requests, hasLength(1));
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
