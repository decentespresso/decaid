import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/feedback_service.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.docsDir);

  final Directory docsDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsDir.path;
}

class _MemoryCredentialStore implements CredentialStore {
  _MemoryCredentialStore(this._values);

  final Map<String, String> _values;

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}

void main() {
  test('scrubs serials from logs when the serial provider is empty', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'feedback_service_test',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));

    PathProviderPlatform.instance = _FakePathProvider(tempDir);

    File('${tempDir.path}/log.txt').writeAsStringSync(
      'device connected {"machineInfo":{"serialNumber":"SN123456"}}\n'
      'another line serialNumber: SN999888\n',
    );

    final service = FeedbackService(
      githubToken: 'token',
      currentSerialNumbers: () => const [],
    );

    final report = await service.generateHtmlReport(
      FeedbackRequest(
        description: 'test',
        type: FeedbackType.bug,
        includeLogs: true,
        includeSystemInfo: false,
      ),
    );

    expect(report, isNot(contains('SN123456')));
    expect(report, isNot(contains('SN999888')));
    expect(report, contains('serial_'));
  });

  test(
    'preserves the current GitHub body when patching the contact id',
    () async {
      const issueUrl = 'https://github.com/decentespresso/decaid/issues/728';
      const contactId = 'GhwAHSEAAAAAAAAGBgAdAxAcCUgGCgQ=';
      const currentBody =
          '## Description\nThe steam control stopped responding.\n\n'
          'Bot-added triage details.\n';
      final requests = <http.Request>[];

      Future<http.Response> handle(http.Request request) async {
        requests.add(request);
        return switch (requests.length) {
          1 => http.Response(
            jsonEncode({'number': 728, 'html_url': issueUrl}),
            201,
          ),
          2 => http.Response(contactId, 200),
          3 => http.Response(jsonEncode({'body': currentBody}), 200),
          4 => http.Response('{}', 200),
          _ => http.Response('unexpected request', 500),
        };
      }

      final accountService = DecentAccountService(
        httpClient: http_testing.MockClient(handle),
        credentialStore: _MemoryCredentialStore({
          'email': 'test@example.com',
          'password': 'cryptpw_abc123',
        }),
      );
      final service = FeedbackService(
        githubToken: 'github-token',
        currentSerialNumbers: () => const [],
        accountService: accountService,
      );

      final result = await http.runWithClient(
        () => service.submitFeedback(
          FeedbackRequest(
            description: 'The steam control stopped responding.',
            type: FeedbackType.bug,
            includeLogs: false,
            includeSystemInfo: false,
          ),
        ),
        () => http_testing.MockClient(handle),
      );

      expect(result.success, isTrue);
      expect(result.issueNumber, 728);
      expect(result.issueUrl, issueUrl);
      expect(requests.map((request) => request.method), [
        'POST',
        'GET',
        'GET',
        'PATCH',
      ]);
      expect(requests[0].url.path, '/repos/decentespresso/decaid/issues');

      final initialIssue = jsonDecode(requests[0].body) as Map<String, dynamic>;
      expect(initialIssue['body'], isNot(contains('**Contact:**')));

      expect(requests[1].url.path, '/support/api/email');
      expect(requests[1].url.queryParameters['body'], issueUrl);
      expect(
        requests[1].url.queryParameters['subject'],
        'Decaid feedback #728',
      );
      expect(requests[1].headers['authorization'], startsWith('Basic '));

      expect(requests[2].url.path, '/repos/decentespresso/decaid/issues/728');
      expect(requests[3].url.path, '/repos/decentespresso/decaid/issues/728');
      final update = jsonDecode(requests[3].body) as Map<String, dynamic>;
      expect(update['body'], contains('---\n**Contact:** `$contactId`\n'));
      expect(update['body'], startsWith(currentBody));
      expect(update['body'], contains('Bot-added triage details.'));
    },
  );

  test('returns the GitHub result when Decent Support linking fails', () async {
    const issueUrl = 'https://github.com/decentespresso/decaid/issues/729';
    final requests = <http.Request>[];

    Future<http.Response> handle(http.Request request) async {
      requests.add(request);
      if (requests.length == 1) {
        return http.Response(
          jsonEncode({'number': 729, 'html_url': issueUrl}),
          201,
        );
      }
      return http.Response('support unavailable', 503);
    }

    final accountService = DecentAccountService(
      httpClient: http_testing.MockClient(handle),
      credentialStore: _MemoryCredentialStore({
        'email': 'test@example.com',
        'password': 'cryptpw_abc123',
      }),
    );
    final service = FeedbackService(
      githubToken: 'github-token',
      currentSerialNumbers: () => const [],
      accountService: accountService,
    );

    final result = await http.runWithClient(
      () => service.submitFeedback(
        FeedbackRequest(
          description: 'Feedback still reaches GitHub.',
          type: FeedbackType.bug,
          includeLogs: false,
          includeSystemInfo: false,
        ),
      ),
      () => http_testing.MockClient(handle),
    );

    expect(result.success, isTrue);
    expect(result.issueNumber, 729);
    expect(result.issueUrl, issueUrl);
    expect(requests.map((request) => request.method), ['POST', 'GET']);
  });

  test('does not patch after Decent Support times out', () async {
    const issueUrl = 'https://github.com/decentespresso/decaid/issues/730';
    final supportResponse = Completer<http.Response>();
    final supportRequested = Completer<void>();
    final githubRequests = <http.Request>[];

    final accountService = DecentAccountService(
      httpClient: http_testing.MockClient((request) {
        supportRequested.complete();
        return supportResponse.future;
      }),
      credentialStore: _MemoryCredentialStore({
        'email': 'test@example.com',
        'password': 'cryptpw_abc123',
      }),
    );
    final service = FeedbackService(
      githubToken: 'github-token',
      currentSerialNumbers: () => const [],
      accountService: accountService,
      supportLinkTimeout: const Duration(milliseconds: 10),
    );

    final submission = http.runWithClient(
      () => service.submitFeedback(
        FeedbackRequest(
          description: 'Support takes too long.',
          type: FeedbackType.bug,
          includeLogs: false,
          includeSystemInfo: false,
        ),
      ),
      () => http_testing.MockClient((request) async {
        githubRequests.add(request);
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({'number': 730, 'html_url': issueUrl}),
            201,
          );
        }
        return http.Response('unexpected request', 500);
      }),
    );

    await supportRequested.future;
    final result = await submission;
    supportResponse.complete(http.Response('late.contact', 200));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(result.success, isTrue);
    expect(result.issueNumber, 730);
    expect(githubRequests.map((request) => request.method), ['POST']);
  });
}
