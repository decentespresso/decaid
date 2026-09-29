import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/models/feedback/feedback_result.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:reaprime/src/services/webserver/feedback_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

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
              return http.Response(
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
