import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/util/remote_update_report.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

class FakeWebUIStorage extends Fake implements WebUIStorage {
  Object? remoteError;
  bool installFromGitHubReleaseCalled = false;
  bool installFromGitHubCalled = false;
  bool installFromUrlCalled = false;
  List<RemoteUpdateItemResult> updateResults = const [];

  @override
  Future<void> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    installFromGitHubReleaseCalled = true;
    if (remoteError != null) throw remoteError!;
  }

  @override
  Future<void> installFromGitHub(String repo, {String branch = 'main'}) async {
    installFromGitHubCalled = true;
    if (remoteError != null) throw remoteError!;
  }

  @override
  Future<void> installFromUrl(
    String url, {
    String? sourceIdentifier,
    String? releaseAssetName,
    bool? includePrerelease,
  }) async {
    installFromUrlCalled = true;
    if (remoteError != null) throw remoteError!;
  }

  @override
  Future<void> updateAllSkins() async {
    if (remoteError != null) throw remoteError!;
  }

  @override
  Future<RemoteUpdateReport> checkForSkinUpdates() async {
    if (remoteError != null) throw remoteError!;
    return RemoteUpdateReport(updateResults);
  }
}

void main() {
  late FakeWebUIStorage fakeStorage;

  setUp(() {
    fakeStorage = FakeWebUIStorage();
  });

  Handler buildHandler() {
    final webUIHandler = WebUIHandler(
      storage: fakeStorage,
      service: WebUIService(),
    );
    final app = Router().plus;
    webUIHandler.addRoutes(app);
    return app.call;
  }

  Future<Response> sendPost(
    Handler handler,
    String path,
    Map<String, dynamic> body,
  ) async {
    return await handler(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      ),
    );
  }

  group('WebUIHandler skin installation', () {
    group('installation endpoints', () {
      late Handler handler;

      setUp(() {
        handler = buildHandler();
      });

      test(
        'all online install routes return friendly connection errors',
        () async {
          fakeStorage.remoteError = const SocketException(
            'private host lookup',
          );
          for (final source in ['github-release', 'github-branch', 'url']) {
            final response = await sendPost(
              handler,
              '/api/v1/webui/skins/install/$source',
              {'repo': 'user/repo', 'url': 'https://example.test/skin.zip'},
            );
            expect(response.statusCode, 500);
            expect(
              jsonDecode(await response.readAsString())['error'],
              "Couldn't install the skin. Check your internet connection and try again.",
            );
          }
        },
      );

      test(
        'POST /api/v1/webui/skins/install/github-release calls storage',
        () async {
          final response = await sendPost(
            handler,
            '/api/v1/webui/skins/install/github-release',
            {'repo': 'user/repo'},
          );
          expect(response.statusCode, 200);
          expect(fakeStorage.installFromGitHubReleaseCalled, isTrue);
        },
      );

      test(
        'POST /api/v1/webui/skins/install/github-branch calls storage',
        () async {
          final response = await sendPost(
            handler,
            '/api/v1/webui/skins/install/github-branch',
            {'repo': 'user/repo'},
          );
          expect(response.statusCode, 200);
          expect(fakeStorage.installFromGitHubCalled, isTrue);
        },
      );

      test('POST /api/v1/webui/skins/install/url calls storage', () async {
        final response = await sendPost(
          handler,
          '/api/v1/webui/skins/install/url',
          {'url': 'https://example.com/skin.zip'},
        );
        expect(response.statusCode, 200);
        expect(fakeStorage.installFromUrlCalled, isTrue);
      });

      test(
        'POST /api/v1/webui/skins/update returns per-item outcomes',
        () async {
          fakeStorage.updateResults = [
            const RemoteUpdateItemResult(
              item: 'acme/updated',
              status: RemoteUpdateStatus.updated,
            ),
            const RemoteUpdateItemResult(
              item: 'acme/current',
              status: RemoteUpdateStatus.alreadyCurrent,
            ),
            const RemoteUpdateItemResult(
              item: 'acme/broken',
              status: RemoteUpdateStatus.failed,
              error: SocketException('offline'),
            ),
          ];

          final response = await handler(
            Request(
              'POST',
              Uri.parse('http://localhost/api/v1/webui/skins/update'),
            ),
          );
          expect(response.statusCode, 200);
          final body =
              jsonDecode(await response.readAsString()) as Map<String, dynamic>;
          expect(body['message'], 'Skin update check completed');
          final results = (body['results'] as List)
              .cast<Map<String, dynamic>>();
          expect(results.map((result) => result['item']), [
            'acme/updated',
            'acme/current',
            'acme/broken',
          ]);
          expect(results.map((result) => result['status']), [
            'updated',
            'alreadyCurrent',
            'failed',
          ]);
          expect(results.first.containsKey('error'), isFalse);
          expect(results[1].containsKey('error'), isFalse);
          expect(
            results.last['error'],
            'Check your internet connection and try again.',
          );
        },
      );

      test(
        'POST /api/v1/webui/skins/update reports a failed check as 500',
        () async {
          fakeStorage.remoteError = const SocketException('offline');

          final response = await handler(
            Request(
              'POST',
              Uri.parse('http://localhost/api/v1/webui/skins/update'),
            ),
          );

          expect(response.statusCode, 500);
          expect(
            jsonDecode(await response.readAsString())['error'],
            "Couldn't check for skin updates. Check your internet connection "
            'and try again.',
          );
        },
      );
    });
  });
}
