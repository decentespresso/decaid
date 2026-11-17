import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/models/feedback/feedback_result.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/webserver/feedback_handler.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_plus/shelf_plus.dart';

class _GithubStore implements CredentialStore {
  _GithubStore(this.value);

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

class _CredentialStore extends Fake implements CredentialStore {
  final bool hasCredentials;

  _CredentialStore(this.hasCredentials);

  @override
  Future<String?> read({required String key}) async =>
      hasCredentials ? 'test-value' : null;

  @override
  Future<void> write({required String key, required String value}) async {}
}

void main() {
  for (final configured in [true, false]) {
    for (final scenario in [
      'missing service',
      'no credentials',
      'rejected credentials',
      'verification unavailable',
      'network failure',
      'authenticated',
    ]) {
      test(
        'feedback HTTP submission: $scenario, configured: $configured',
        () async {
          final events = <String>[];
          final authenticated = scenario == 'authenticated';
          final account = DecentAccountService(
            credentialStore: _CredentialStore(scenario != 'no credentials'),
            httpClient: MockClient((request) async {
              events.add(request.url.path);
              return switch (request.url.path) {
                '/support/api/login_test' => switch (scenario) {
                  'rejected credentials' => http.Response('0', 401),
                  'verification unavailable' => http.Response(
                    'unavailable',
                    503,
                  ),
                  'network failure' => throw http.ClientException('offline'),
                  _ => http.Response('token', 200),
                },
                '/support/api/email' => http.Response('1', 200),
                _ => http.Response('', 200),
              };
            }),
          );
          final service = FeedbackService(
            githubToken: configured ? 'test-token' : '',
            currentSerialNumbers: () => const [],
            accountService: scenario == 'missing service' ? null : account,
          );
          final router = Router().plus;
          FeedbackHandler(service: service).addRoutes(router);
          final response = await http.runWithClient(
            () async {
              final response = await router.call(
                Request(
                  'POST',
                  Uri.parse('http://localhost/api/v1/feedback'),
                  body: jsonEncode({
                    'description': 'Test report',
                    'includeLogs': false,
                    'includeSystemInfo': false,
                  }),
                ),
              );
              final result = await service.submitFeedback(
                FeedbackRequest(
                  description: 'Direct report with attachment',
                  type: FeedbackType.bug,
                  includeLogs: false,
                  includeSystemInfo: false,
                  screenshots: [
                    Uint8List.fromList([1, 2, 3]),
                  ],
                ),
              );
              expect(result.success, authenticated && configured);
              if (!authenticated) {
                expect(
                  result.failureReason,
                  FeedbackFailureReason.accountRequired,
                );
              }
              return response;
            },
            () => MockClient((request) async {
              events.add('${request.method} ${request.url.path}');
              return request.url.path == '/gists'
                  ? http.Response(
                      jsonEncode({
                        'html_url':
                            'https://gist.github.com/test/abcdef0123456789',
                      }),
                      201,
                    )
                  : http.Response(
                      jsonEncode({
                        'number': 123,
                        'html_url': 'https://github.com/example/issues/123',
                      }),
                      201,
                    );
            }),
          );

          expect(
            response.statusCode,
            authenticated ? (configured ? 201 : 503) : 400,
          );
          final body = jsonDecode(await response.readAsString());
          if (authenticated && !configured) {
            expect(body['error'], 'Service unavailable');
            expect(
              events.where(
                (event) => ![
                  '/support/api/login_test',
                  '/support/api/sn',
                ].contains(event),
              ),
              isEmpty,
            );
          } else if (authenticated) {
            expect(body['success'], isTrue);
            expect(events.first, '/support/api/login_test');
            expect(events, contains('POST /gists'));
            expect(
              events,
              contains('POST /repos/decentespresso/decaid/issues'),
            );
            expect(events, contains('/support/api/email'));
            expect(events.where((e) => e.startsWith('PATCH')), isEmpty);
            expect(events.where((e) => e.startsWith('GET /repos')), isEmpty);
          } else {
            expect(body['success'], isFalse);
            expect(body['error'], 'Decent account required');
            expect(
              body['message'],
              contains(
                scenario == 'verification unavailable' ||
                        scenario == 'network failure'
                    ? 'Could not verify your Decent account'
                    : 'You must be logged in to your Decent account',
              ),
            );
            expect(
              events.where((e) => !e.startsWith('/support/api/login_test')),
              isEmpty,
            );
          }
        },
      );
    }
  }

  test('REST feedback follows live user PAT replacement and removal', () async {
    final credentials = GithubCredentialProvider(store: _GithubStore(null));
    final account = DecentAccountService(
      credentialStore: _CredentialStore(true),
      httpClient: MockClient((request) async {
        if (request.url.path == '/support/api/login_test') {
          return http.Response('token', 200);
        }
        return http.Response('', 200);
      }),
    );
    final service = FeedbackService(
      githubToken: 'bundled-pat',
      credentials: credentials,
      currentSerialNumbers: () => const [],
      accountService: account,
    );
    final router = Router().plus;
    FeedbackHandler(service: service).addRoutes(router);
    final githubRequests = <http.Request>[];

    Future<shelf.Response> submit() async {
      return http.runWithClient(
        () => router.call(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/feedback'),
            body: jsonEncode({
              'description': 'REST feedback',
              'includeLogs': false,
              'includeSystemInfo': false,
            }),
          ),
        ),
        () => MockClient((request) async {
          githubRequests.add(request);
          return http.Response(
            jsonEncode({
              'number': githubRequests.length,
              'html_url':
                  'https://github.com/decentespresso/decaid/issues/${githubRequests.length}',
            }),
            201,
          );
        }),
      );
    }

    expect((await submit()).statusCode, isIn([200, 201]));
    await credentials.save('user-pat');
    expect((await submit()).statusCode, isIn([200, 201]));
    await credentials.remove();
    expect((await submit()).statusCode, isIn([200, 201]));
    expect(githubRequests.map((request) => request.headers['authorization']), [
      'Bearer bundled-pat',
      'Bearer user-pat',
      'Bearer bundled-pat',
    ]);
  });

  test(
    'missing account fails before configuration or attachment work',
    () async {
      final service = FeedbackService(
        githubToken: '',
        currentSerialNumbers: () => throw StateError('must not collect data'),
      );
      final result = await service.submitFeedback(
        FeedbackRequest(
          description: 'Test',
          type: FeedbackType.bug,
          screenshots: [
            Uint8List.fromList([1]),
          ],
        ),
      );

      expect(result.failureReason, FeedbackFailureReason.accountRequired);
    },
  );
}
