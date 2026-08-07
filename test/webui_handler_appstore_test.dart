import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

class FakeWebUIStorage extends Fake implements WebUIStorage {
  bool installFromGitHubReleaseCalled = false;
  bool installFromGitHubCalled = false;
  bool installFromUrlCalled = false;

  @override
  Future<void> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    installFromGitHubReleaseCalled = true;
  }

  @override
  Future<void> installFromGitHub(String repo, {String branch = 'main'}) async {
    installFromGitHubCalled = true;
  }

  @override
  Future<void> installFromUrl(
    String url, {
    String? sourceIdentifier,
    String? releaseAssetName,
    bool? includePrerelease,
  }) async {
    installFromUrlCalled = true;
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
    });
  });
}
