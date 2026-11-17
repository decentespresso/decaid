import 'dart:async';
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

class _Credentials extends Fake implements CredentialStore {
  final Completer<String?>? email;

  _Credentials(this.email);

  @override
  Future<String?> read({required String key}) async =>
      key == 'email' && email != null ? await email!.future : 'test-value';
}

class _DelayedClient extends http.BaseClient {
  final response = Completer<http.StreamedResponse>();
  final requests = <http.BaseRequest>[];
  bool aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    if (request is http.AbortableRequest) {
      request.abortTrigger?.then((_) => aborted = true);
    }
    return response.future;
  }
}

void main() {
  for (final phase in ['credentials', 'headers', 'body']) {
    for (final viaHttp in [false, true]) {
      testWidgets('feedback times out during $phase, HTTP: $viaHttp', (
        tester,
      ) async {
        final client = _DelayedClient();
        final email = phase == 'credentials' ? Completer<String?>() : null;
        final body = StreamController<List<int>>();
        final account = DecentAccountService(
          httpClient: client,
          credentialStore: _Credentials(email),
        );
        var accountChanges = 0;
        final subscription = account.identityAuthorityChanges.listen(
          (_) => accountChanges++,
        );
        final service = FeedbackService(
          githubToken: 'test-token',
          accountService: account,
          currentSerialNumbers: () => throw StateError('must not collect logs'),
        );
        final router = Router().plus;
        FeedbackHandler(service: service).addRoutes(router);
        final externalRequests = <http.Request>[];
        Response? httpResult;
        FeedbackSubmissionResult? nativeResult;
        var finished = false;
        http.runWithClient(
          () async {
            if (viaHttp) {
              httpResult = await router.call(
                Request(
                  'POST',
                  Uri.parse('http://localhost/api/v1/feedback'),
                  body: jsonEncode({'description': 'test'}),
                ),
              );
            } else {
              nativeResult = await service.submitFeedback(
                FeedbackRequest(
                  description: 'test',
                  type: FeedbackType.bug,
                  screenshots: [
                    Uint8List.fromList([1, 2, 3]),
                  ],
                ),
              );
            }
            finished = true;
          },
          () => MockClient((request) async {
            externalRequests.add(request);
            return http.Response('unexpected', 500);
          }),
        );
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(client.requests, hasLength(phase == 'credentials' ? 0 : 1));
        if (phase == 'body') {
          client.response.complete(http.StreamedResponse(body.stream, 200));
          await tester.pump();
        }
        await tester.pump(const Duration(seconds: 29));
        expect(finished, isFalse);
        await tester.pump(const Duration(seconds: 1));
        expect(finished, isTrue);
        if (viaHttp) {
          expect(httpResult?.statusCode, 400);
        } else {
          expect(
            nativeResult?.failureReason,
            FeedbackFailureReason.accountRequired,
          );
          expect(nativeResult?.errorMessage, contains('Could not verify'));
        }
        expect(client.aborted, phase != 'credentials');
        expect(externalRequests, isEmpty);

        if (phase == 'credentials') {
          email!.complete('test-value');
        } else if (phase == 'headers') {
          client.response.complete(
            http.StreamedResponse(Stream.value(utf8.encode('token')), 200),
          );
        } else {
          body.add(utf8.encode('token'));
        }
        body.close();
        await tester.pump();
        expect(client.requests, hasLength(phase == 'credentials' ? 0 : 1));
        expect(accountChanges, 0);
        expect(externalRequests, isEmpty);
        subscription.cancel();
        await tester.pump();
      });
    }
  }
}
