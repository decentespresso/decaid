import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:logging/logging.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_runtime.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/installed_components.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.docsDir);

  final Directory docsDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsDir.path;
}

DecentAccountService _authenticatedAccountService() {
  return DecentAccountService(
    httpClient: http_testing.MockClient((request) async {
      if (request.url.path == '/support/api/login_test') {
        return http.Response('cryptpw_abc123', 200);
      }
      if (request.url.path == '/support/api/sn') {
        return http.Response('', 200);
      }
      return http.Response('{}', 200);
    }),
    credentialStore: _MemoryCredentialStore({
      'email': 'test@example.com',
      'password': 'cryptpw_abc123',
    }),
  );
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
    'publishes only the message ID and preserves the current GitHub body',
    () async {
      const issueUrl = 'https://github.com/decentespresso/decaid/issues/728';
      const userId = 12345;
      const messageId = 67890;
      const currentBody =
          '## Description\nThe steam control stopped responding.\n\n'
          'Bot-added triage details.\n';
      final requests = <http.Request>[];

      Future<http.Response> handle(http.Request request) async {
        if (request.url.path == '/support/api/login_test') {
          return http.Response('cryptpw_abc123', 200);
        }
        if (request.url.path == '/support/api/sn') {
          return http.Response('', 200);
        }
        requests.add(request);
        return switch (requests.length) {
          1 => http.Response(
            jsonEncode({'number': 728, 'html_url': issueUrl}),
            201,
          ),
          2 => http.Response(
            jsonEncode({'userId': userId, 'messageId': messageId}),
            200,
          ),
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
      expect(result.supportLink, 'linked');
      expect(requests.map((request) => request.method), [
        'POST',
        'GET',
        'GET',
        'PATCH',
      ]);
      expect(requests[0].url.path, '/repos/decentespresso/decaid/issues');

      final initialIssue = jsonDecode(requests[0].body) as Map<String, dynamic>;
      expect(initialIssue['body'], isNot(contains('**Support message:**')));

      expect(requests[1].url.path, '/support/api/email');
      expect(
        requests[1].url.queryParameters['body'],
        'Hi,\n\n'
        'I recently submitted feedback from Decaid: $issueUrl\n\n'
        'This message was sent automatically by Decaid for reference and '
        'to keep the feedback linked to my support history.',
      );
      expect(
        requests[1].url.queryParameters['subject'],
        'Decaid feedback #728',
      );
      expect(requests[1].headers['authorization'], startsWith('Basic '));

      expect(requests[2].url.path, '/repos/decentespresso/decaid/issues/728');
      expect(requests[3].url.path, '/repos/decentespresso/decaid/issues/728');
      final update = jsonDecode(requests[3].body) as Map<String, dynamic>;
      expect(
        update['body'],
        contains('---\n**Support message:** `$messageId`\n'),
      );
      expect(update['body'], isNot(contains('$userId')));
      expect(update['body'], isNot(contains('**Contact:**')));
      for (final request in requests.where(
        (r) => r.url.host == 'api.github.com',
      )) {
        expect(request.body, isNot(contains('$userId')));
        expect(request.body, isNot(contains('userId')));
      }
      expect(update['body'], startsWith(currentBody));
      expect(update['body'], contains('Bot-added triage details.'));
    },
  );

  for (final scenario in [
    (name: 'unavailable', response: http.Response('support unavailable', 503)),
    (
      name: 'malformed receipt',
      response: http.Response('{"userId":12345,', 200),
    ),
    (
      name: 'invalid message ID',
      response: http.Response('{"userId":12345,"messageId":{}}', 200),
    ),
    (
      name: 'email address as message ID',
      response: http.Response('{"messageId":"customer@example.com"}', 200),
    ),
    (
      name: 'opaque message ID',
      response: http.Response('{"messageId":"msg-67890"}', 200),
    ),
  ]) {
    test(
      'returns the GitHub result without leaking private IDs: ${scenario.name}',
      () async {
        const issueUrl = 'https://github.com/decentespresso/decaid/issues/729';
        final requests = <http.Request>[];
        final logs = <LogRecord>[];
        final subscription = Logger.root.onRecord.listen(logs.add);
        addTearDown(subscription.cancel);

        Future<http.Response> handle(http.Request request) async {
          if (request.url.path == '/support/api/login_test') {
            return http.Response('cryptpw_abc123', 200);
          }
          if (request.url.path == '/support/api/sn') {
            return http.Response('', 200);
          }
          requests.add(request);
          if (requests.length == 1) {
            return http.Response(
              jsonEncode({'number': 729, 'html_url': issueUrl}),
              201,
            );
          }
          return scenario.response;
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
        expect(jsonEncode(result.toJson()), isNot(contains('12345')));
        for (final privateValue in ['customer@example.com', 'msg-67890']) {
          expect(jsonEncode(result.toJson()), isNot(contains(privateValue)));
          for (final request in requests.where(
            (request) => request.url.host == 'api.github.com',
          )) {
            expect(request.body, isNot(contains(privateValue)));
          }
          for (final record in logs) {
            expect(
              '${record.message} ${record.error}',
              isNot(contains(privateValue)),
            );
          }
        }
        for (final record in logs) {
          expect('${record.message} ${record.error}', isNot(contains('12345')));
          expect(
            '${record.message} ${record.error}',
            isNot(contains('userId')),
          );
        }
      },
    );
  }

  test('does not patch after Decent Support times out', () async {
    const issueUrl = 'https://github.com/decentespresso/decaid/issues/730';
    final supportResponse = Completer<http.Response>();
    final supportRequested = Completer<void>();
    final githubRequests = <http.Request>[];

    final accountService = DecentAccountService(
      httpClient: http_testing.MockClient((request) {
        if (request.url.path == '/support/api/login_test') {
          return Future.value(http.Response('cryptpw_abc123', 200));
        }
        if (request.url.path == '/support/api/sn') {
          return Future.value(http.Response('', 200));
        }
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
    supportResponse.complete(http.Response('{"messageId":67890}', 200));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(result.success, isTrue);
    expect(result.issueNumber, 730);
    expect(githubRequests.map((request) => request.method), ['POST']);
  });

  test(
    'user credential is used for issue and support reference requests',
    () async {
      const issueUrl = 'https://github.com/decentespresso/decaid/issues/731';
      final githubRequests = <http.Request>[];
      final accountService = DecentAccountService(
        httpClient: http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/login_test') {
            return http.Response('cryptpw_abc123', 200);
          }
          if (request.url.path == '/support/api/sn') {
            return http.Response('', 200);
          }
          return http.Response(jsonEncode({'messageId': 67890}), 200);
        }),
        credentialStore: _MemoryCredentialStore({
          'email': 'test@example.com',
          'password': 'cryptpw_abc123',
        }),
      );
      final credentials = GithubCredentialProvider(
        store: _MemoryCredentialStore({
          GithubCredentialProvider.storageKey: 'user-pat',
        }),
      );
      await credentials.load();
      final service = FeedbackService(
        githubToken: 'bundled-pat',
        credentials: credentials,
        currentSerialNumbers: () => const [],
        accountService: accountService,
      );

      final result = await http.runWithClient(
        () => service.submitFeedback(
          FeedbackRequest(
            description: 'User credential feedback',
            type: FeedbackType.bug,
            includeLogs: false,
            includeSystemInfo: false,
          ),
        ),
        () => http_testing.MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            githubRequests.add(request);
            return switch (githubRequests.length) {
              1 => http.Response(
                jsonEncode({'number': 731, 'html_url': issueUrl}),
                201,
              ),
              2 => http.Response(jsonEncode({'body': 'current'}), 200),
              3 => http.Response('{}', 200),
              _ => http.Response('unexpected request', 500),
            };
          }
          return http.Response('unexpected request', 500);
        }),
      );

      expect(result.success, isTrue);
      expect(githubRequests.map((request) => request.method), [
        'POST',
        'GET',
        'PATCH',
      ]);
      for (final request in githubRequests) {
        expect(request.headers['authorization'], 'Bearer user-pat');
        expect(request.followRedirects, isFalse);
      }
    },
  );

  test(
    'feedback keeps one credential across account verification and gist work',
    () async {
      for (final phase in ['account verification', 'gist']) {
        final credentials = GithubCredentialProvider(
          store: _MemoryCredentialStore({
            GithubCredentialProvider.storageKey: 'old-pat',
          }),
        );
        await credentials.load();
        final githubRequests = <http.Request>[];
        final supportRequests = <http.Request>[];
        final account = DecentAccountService(
          httpClient: http_testing.MockClient((request) async {
            supportRequests.add(request);
            if (request.url.path == '/support/api/login_test') {
              if (phase == 'account verification') {
                await credentials.save('new-pat');
              }
              return http.Response('cryptpw_abc123', 200);
            }
            if (request.url.path == '/support/api/email') {
              return http.Response('{"messageId":67890}', 200);
            }
            return http.Response('', 200);
          }),
          credentialStore: _MemoryCredentialStore({
            'email': 'test@example.com',
            'password': 'cryptpw_abc123',
          }),
        );
        final service = FeedbackService(
          githubToken: 'bundled-pat',
          credentials: credentials,
          currentSerialNumbers: () => const [],
          accountService: account,
          httpClient: http_testing.MockClient((request) async {
            githubRequests.add(request);
            if (request.url.path == '/gists' && phase == 'gist') {
              await credentials.save('new-pat');
            }
            return switch (request.url.path) {
              '/gists' => http.Response(
                jsonEncode({
                  'html_url': 'https://gist.github.com/test/abcdef0123456789',
                }),
                201,
              ),
              '/repos/decentespresso/decaid/issues' => http.Response(
                jsonEncode({
                  'number': 734,
                  'html_url':
                      'https://github.com/decentespresso/decaid/issues/734',
                }),
                201,
              ),
              '/repos/decentespresso/decaid/issues/734' =>
                request.method == 'GET'
                    ? http.Response(jsonEncode({'body': 'current'}), 200)
                    : http.Response('{}', 200),
              _ => http.Response('unexpected request', 500),
            };
          }),
        );

        final result = await service.submitFeedback(
          FeedbackRequest(
            description: 'Stable identity feedback',
            type: FeedbackType.bug,
            includeLogs: false,
            includeSystemInfo: false,
            screenshots: [
              Uint8List.fromList([1]),
            ],
          ),
        );

        expect(result.success, isTrue, reason: phase);
        expect(githubRequests.map((request) => request.method), [
          'POST',
          'POST',
          'GET',
          'PATCH',
        ]);
        expect(
          githubRequests.map((request) => request.headers['authorization']),
          everyElement('Bearer old-pat'),
        );
        for (final request in supportRequests) {
          expect(request.headers['authorization'], isNot('Bearer old-pat'));
          expect(request.url.toString(), isNot(contains('old-pat')));
          expect(request.url.toString(), isNot(contains('new-pat')));
          expect(request.body, isNot(contains('old-pat')));
          expect(request.body, isNot(contains('new-pat')));
        }
        expect(credentials.current.authorizationHeader, 'Bearer new-pat');
      }
    },
  );

  test('user issue authorization failures do not fall back', () async {
    for (final status in [401, 403, 404]) {
      final credentials = GithubCredentialProvider(
        store: _MemoryCredentialStore({
          GithubCredentialProvider.storageKey: 'user-pat',
        }),
      );
      await credentials.load();
      final requests = <http.Request>[];
      final service = FeedbackService(
        githubToken: 'bundled-pat',
        credentials: credentials,
        currentSerialNumbers: () => const [],
        accountService: _authenticatedAccountService(),
        httpClient: http_testing.MockClient((request) async {
          requests.add(request);
          return http.Response('secret response payload', status);
        }),
      );

      final result = await service.submitFeedback(
        FeedbackRequest(
          description: 'Issue authorization failure',
          type: FeedbackType.bug,
          includeLogs: false,
          includeSystemInfo: false,
        ),
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('Advanced Settings'));
      expect(result.errorMessage, isNot(contains('secret')));
      expect(requests, hasLength(1));
      expect(requests.single.headers['authorization'], 'Bearer user-pat');
    }
  });

  test('attachment upload failure does not create an issue', () async {
    final credentials = GithubCredentialProvider(
      store: _MemoryCredentialStore({
        GithubCredentialProvider.storageKey: 'user-pat',
      }),
    );
    await credentials.load();
    final requests = <http.Request>[];
    final service = FeedbackService(
      githubToken: 'bundled-pat',
      credentials: credentials,
      currentSerialNumbers: () => const [],
      accountService: _authenticatedAccountService(),
      httpClient: http_testing.MockClient((request) async {
        requests.add(request);
        return http.Response('permission denied', 403);
      }),
    );

    final result = await service.submitFeedback(
      FeedbackRequest(
        description: 'With attachment',
        type: FeedbackType.bug,
        includeLogs: false,
        includeSystemInfo: false,
        screenshots: [
          Uint8List.fromList([1]),
        ],
      ),
    );

    expect(result.success, isFalse);
    expect(result.errorMessage, contains('Gists write permission'));
    expect(result.errorMessage, contains('Advanced Settings'));
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/gists');
  });

  test('invalid gist URL cannot reach the issue body', () async {
    final credentials = GithubCredentialProvider(
      store: _MemoryCredentialStore({
        GithubCredentialProvider.storageKey: 'abcdef1234',
      }),
    );
    await credentials.load();
    final requests = <http.Request>[];
    final service = FeedbackService(
      githubToken: 'bundled-pat',
      credentials: credentials,
      currentSerialNumbers: () => const [],
      accountService: _authenticatedAccountService(),
      httpClient: http_testing.MockClient((request) async {
        requests.add(request);
        return request.url.path == '/gists'
            ? http.Response(
                jsonEncode({
                  'html_url': 'https://gist.github.com/user/abcdef1234',
                }),
                201,
              )
            : http.Response(
                jsonEncode({'number': 732, 'html_url': 'bad'}),
                201,
              );
      }),
    );

    final result = await service.submitFeedback(
      FeedbackRequest(
        description: 'With attachment',
        type: FeedbackType.bug,
        includeLogs: false,
        includeSystemInfo: false,
        screenshots: [
          Uint8List.fromList([1]),
        ],
      ),
    );

    expect(result.success, isFalse);
    expect(result.errorMessage, isNot(contains('abcdef1234')));
    expect(requests, hasLength(1));
  });

  test(
    'selected credential remains stable when replaced during gist upload',
    () async {
      final credentials = GithubCredentialProvider(
        store: _MemoryCredentialStore({
          GithubCredentialProvider.storageKey: 'old-pat',
        }),
      );
      await credentials.load();
      final requests = <http.Request>[];
      final service = FeedbackService(
        githubToken: 'bundled-pat',
        credentials: credentials,
        currentSerialNumbers: () => const [],
        accountService: _authenticatedAccountService(),
        httpClient: http_testing.MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/gists') {
            await credentials.save('new-pat');
            return http.Response(
              jsonEncode({
                'html_url': 'https://gist.github.com/owner/abcdef1234',
              }),
              201,
            );
          }
          return http.Response(
            jsonEncode({'number': 733, 'html_url': 'bad'}),
            201,
          );
        }),
      );

      final result = await service.submitFeedback(
        FeedbackRequest(
          description: 'contains old-pat',
          type: FeedbackType.bug,
          includeLogs: false,
          includeSystemInfo: false,
          screenshots: [
            Uint8List.fromList([1]),
          ],
        ),
      );

      expect(result.success, isTrue);
      expect(requests.map((request) => request.headers['authorization']), [
        'Bearer old-pat',
        'Bearer old-pat',
      ]);
      final issue = jsonDecode(requests[1].body) as Map<String, dynamic>;
      expect(issue['title'], isNot(contains('old-pat')));
      expect(issue['body'], isNot(contains('old-pat')));
      expect(issue['body'], isNot(contains('new-pat')));
    },
  );

  test('system info carries the served skin and the loaded plugins', () async {
    final service = FeedbackService(
      githubToken: 'token',
      currentSerialNumbers: () => const [],
      installedComponents: () => installedComponentLines(
        isServing: true,
        servedPath: '/skins/streamline.js',
        installedSkins: [
          WebUISkin(
            id: 'streamline.js',
            name: 'Streamline',
            path: '/skins/streamline.js',
            version: '0.2.19',
          ),
        ],
        loadedPlugins: [
          PluginRuntime(
            pluginId: 'dye2.reaplugin',
            manifest: PluginManifest.fromJson(const {
              'id': 'dye2.reaplugin',
              'name': 'DYE2',
              'author': 'test',
              'description': 'test',
              'version': '1.3.0',
              'apiVersion': 1,
              'permissions': ['log'],
              'api': [],
            }),
          ),
        ],
      ),
    );

    final report = await service.generateHtmlReport(
      FeedbackRequest(
        description: 'profile change is not applied',
        type: FeedbackType.bug,
        includeLogs: false,
        includeSystemInfo: true,
      ),
    );

    expect(report, contains('Skin: streamline.js 0.2.19'));
    expect(report, contains('Loaded plugins: dye2.reaplugin 1.3.0'));
  });

  test('scrubs the selected PAT from system info and generated HTML', () async {
    const pat = 'user-pat-system-info';
    final credentials = GithubCredentialProvider(
      store: _MemoryCredentialStore({GithubCredentialProvider.storageKey: pat}),
    );
    await credentials.load();
    final service = FeedbackService(
      githubToken: 'bundled-pat',
      credentials: credentials,
      currentSerialNumbers: () => const [],
      installedComponents: () => ['Loaded plugin version $pat'],
    );

    final report = await service.generateHtmlReport(
      FeedbackRequest(
        description: 'Description mentions $pat',
        type: FeedbackType.bug,
        includeLogs: false,
        includeSystemInfo: true,
      ),
    );

    expect(report, isNot(contains(pat)));
    expect(report, contains('Loaded plugin version serial_'));
  });

  test('a provider that throws does not cost us the report', () async {
    final service = FeedbackService(
      githubToken: 'token',
      currentSerialNumbers: () => const [],
      installedComponents: () => throw StateError('skins not loaded'),
    );

    final report = await service.generateHtmlReport(
      FeedbackRequest(
        description: 'profile change is not applied',
        type: FeedbackType.bug,
        includeLogs: false,
        includeSystemInfo: true,
      ),
    );

    expect(report, contains('System Information'));
    expect(report, isNot(contains('Skin:')));
  });
}
