import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/util/remote_error.dart';
import 'package:reaprime/src/util/remote_update_exception.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_settings_service.dart';
import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final resetAt = DateTime.utc(2030, 1, 1, 12);
  final beforeReset = DateTime.utc(2030, 1, 1, 11);
  String resetValue() => '${resetAt.millisecondsSinceEpoch ~/ 1000}';

  Map<String, dynamic> manifestJson(String pluginId) => {
    'id': pluginId,
    'author': 'Test',
    'name': 'Test plugin',
    'description': 'Test plugin',
    'version': '1.0.0',
    'apiVersion': 1,
    'permissions': <String>[],
    'settings': <String, dynamic>{},
    'api': <Object>[],
  };

  List<int> pluginArchive(String pluginId) {
    final archive = Archive();
    archive.addFile(
      ArchiveFile.string(
        'repo-main/manifest.json',
        jsonEncode(manifestJson(pluginId)),
      ),
    );
    archive.addFile(
      ArchiveFile.string('repo-main/plugin.js', 'function createPlugin() {}'),
    );
    return ZipEncoder().encode(archive);
  }

  String releaseJson() => jsonEncode({
    'tag_name': 'v1.0.0',
    'assets': [
      {
        'name': 'plugin.zip',
        'browser_download_url': 'https://example.test/assets/plugin.zip',
      },
    ],
  });

  group('plugin release rate-limit cooldown', () {
    test(
      'a rate-limited plugin fetch pauses every GitHub-backed check',
      () async {
        final loader = PluginLoaderService(kvStore: FakeKeyValueStoreService());
        final limit = GithubRateLimit(now: () => beforeReset);
        final service = PluginSourceService(loader, rateLimit: limit);
        var requests = 0;
        final client = MockClient((_) async {
          requests++;
          return http.Response(
            'API rate limit exceeded',
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-reset': resetValue(),
            },
          );
        });

        await expectLater(
          http.runWithClient(
            () => service.installFromGitHubRelease('acme/plugin'),
            () => client,
          ),
          throwsA(
            isA<RemoteServiceException>().having(
              (e) => e.userMessage,
              'userMessage',
              allOf(contains('temporarily unavailable'), contains('12:00')),
            ),
          ),
        );
        expect(requests, 1);
        expect(limit.isLimited, isTrue);
        expect(limit.resetAt, resetAt);

        final updater = AndroidUpdater(
          owner: 'o',
          repo: 'r',
          httpClient: client,
          rateLimit: limit,
          now: () => beforeReset,
        );
        await expectLater(
          updater.checkForUpdate('0.1.0'),
          throwsA(
            isA<UpdateCheckException>().having(
              (e) => e.rateLimited,
              'rateLimited',
              isTrue,
            ),
          ),
        );
        expect(requests, 1);

        final settingsController = SettingsController(MockSettingsService());
        await settingsController.loadSettings();
        final storage = WebUIStorage(settingsController, rateLimit: limit);
        await expectLater(
          http.runWithClient(
            () => storage.installFromGitHubRelease('acme/plugin'),
            () => client,
          ),
          throwsException,
        );
        expect(requests, 1);

        await expectLater(
          http.runWithClient(
            () => service.installFromGitHubRelease('acme/plugin'),
            () => client,
          ),
          throwsA(
            isA<RemoteServiceException>().having(
              (e) => e.userMessage,
              'userMessage',
              contains('temporarily unavailable'),
            ),
          ),
        );
        expect(requests, 1);
      },
    );

    test(
      'a limited holder keeps plugin update checks off the network',
      () async {
        SharedPreferences.setMockInitialValues({});
        final tempDir = Directory.systemTemp.createTempSync(
          'plugin_rate_limit_test',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => tempDir.path,
            );
        final loader = PluginLoaderService(kvStore: FakeKeyValueStoreService());
        await loader.initialize();
        addTearDown(() async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              );
          await loader.dispose();
          if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        });

        const id = 'managed.reaplugin';
        final releaseClient = MockClient((request) async {
          final url = request.url.toString();
          if (url.contains('/releases/latest')) {
            return http.Response(releaseJson(), 200);
          }
          return http.Response.bytes(pluginArchive(id), 200);
        });
        final limit = GithubRateLimit(now: () => beforeReset);
        final service = PluginSourceService(loader, rateLimit: limit);
        await http.runWithClient(
          () => service.installFromGitHubRelease('acme/plugin'),
          () => releaseClient,
        );
        expect(service.sourceFor(id)?.releaseTag, 'v1.0.0');

        limit.recordIfLimited(
          http.Response(
            '',
            429,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-reset': resetValue(),
            },
          ),
        );
        expect(limit.isLimited, isTrue);

        var requests = 0;
        final exploding = MockClient((_) async {
          requests++;
          return http.Response(releaseJson(), 200);
        });
        await expectLater(
          http.runWithClient(service.updateAllPlugins, () => exploding),
          throwsA(isA<RemoteUpdateException>()),
        );
        expect(requests, 0);
        expect(
          service.sourceFor(id)?.lastError,
          contains('temporarily unavailable'),
        );
      },
    );
  });
}
