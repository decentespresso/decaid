import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../plugins/plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('plugin installation API', () {
    late Directory tempDir;
    late PluginLoaderService service;
    late Handler handler;

    const id = 'installed.reaplugin';

    Map<String, dynamic> manifestJson({
      String version = '1.0.0',
      List<String> permissions = const [],
    }) => {
      'id': id,
      'author': 'Test',
      'name': 'Test plugin',
      'description': 'Test plugin',
      'version': version,
      'apiVersion': 1,
      'permissions': permissions,
      'settings': <String, dynamic>{},
      'api': <Object>[],
    };

    List<int> pluginArchive({
      String version = '1.0.0',
      List<String> permissions = const [],
    }) {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'repo-main/manifest.json',
            jsonEncode(
              manifestJson(version: version, permissions: permissions),
            ),
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'repo-main/plugin.js',
            'function createPlugin() { return { id: "$id", onLoad() {} }; }',
          ),
        );
      return ZipEncoder().encode(archive);
    }

    MockClient gitHubClient({
      String tag = 'v1.0.0',
      String commit = 'commit-1',
      List<int>? archive,
    }) {
      return MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/releases/latest') ||
            url.contains('/releases/tags/')) {
          return http.Response(
            jsonEncode({
              'tag_name': tag,
              'assets': [
                {
                  'name': 'plugin.zip',
                  'browser_download_url': 'https://example.test/plugin.zip',
                },
              ],
            }),
            200,
          );
        }
        if (url.contains('/commits/')) {
          return http.Response(jsonEncode({'sha': commit}), 200);
        }
        return http.Response.bytes(archive ?? pluginArchive(), 200);
      });
    }

    Future<Response> post(String path, [Object? body]) async => handler(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {'content-type': 'application/json'},
      ),
    );

    Future<Map<String, dynamic>> listedPlugin() async {
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/api/v1/plugins')),
      );
      final list = jsonDecode(await res.readAsString()) as List<dynamic>;
      return list.cast<Map<String, dynamic>>().firstWhere(
        (plugin) => plugin['id'] == id,
      );
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('plugins_handler_install');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tempDir.path,
          );
      service = PluginLoaderService(kvStore: FakeKeyValueStoreService());
      await service.initialize();
      final app = Router().plus;
      PluginsHandler(
        pluginManager: service.pluginManager,
        pluginService: service,
      ).addRoutes(app);
      handler = app.call;
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await service.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('installs from a GitHub release and lists the source', () async {
      final res = await http.runWithClient(
        () => post('/api/v1/plugins/install/github-release', {
          'repo': 'acme/plugin',
        }),
        gitHubClient,
      );

      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body, containsPair('id', id));
      expect(body, containsPair('version', '1.0.0'));

      final listed = await listedPlugin();
      expect(listed['source']['kind'], 'github_release');
      expect(listed['source']['repo'], 'acme/plugin');
      expect(listed['source']['releaseTag'], 'v1.0.0');
      expect(listed['pendingUpdate'], isNull);
    });

    test('installs from a GitHub branch', () async {
      final res = await http.runWithClient(
        () => post('/api/v1/plugins/install/github-branch', {
          'repo': 'acme/plugin',
          'branch': 'dev',
        }),
        () => gitHubClient(commit: 'abcdef'),
      );

      expect(res.statusCode, 200);
      final listed = await listedPlugin();
      expect(listed['source']['kind'], 'github_branch');
      expect(listed['source']['branch'], 'dev');
      expect(listed['source']['commit'], 'abcdef');
    });

    test('rejects a missing repo with 400', () async {
      final res = await post('/api/v1/plugins/install/github-release', {});
      expect(res.statusCode, 400);
    });

    test('rejects a tag that disagrees with the manifest with 400', () async {
      final res = await http.runWithClient(
        () => post('/api/v1/plugins/install/github-release', {
          'repo': 'acme/plugin',
        }),
        () => gitHubClient(tag: 'v9.9.9'),
      );

      expect(res.statusCode, 400);
      expect(await res.readAsString(), contains('does not match'));
    });

    test(
      'the URL installer stays unimplemented and points elsewhere',
      () async {
        final res = await post('/api/v1/plugins/install', {
          'url': 'https://example.test/plugin.zip',
        });

        expect(res.statusCode, 501);
        expect(await res.readAsString(), contains('github-release'));
      },
    );

    test('update-all reports success', () async {
      await http.runWithClient(
        () => post('/api/v1/plugins/install/github-branch', {
          'repo': 'acme/plugin',
        }),
        () => gitHubClient(commit: 'first'),
      );

      final res = await http.runWithClient(
        () => post('/api/v1/plugins/update'),
        () => gitHubClient(commit: 'second'),
      );

      expect(res.statusCode, 200);
      final listed = await listedPlugin();
      expect(listed['source']['commit'], 'second');
    });

    test('a permission-escalating update is listed as pending', () async {
      await http.runWithClient(
        () => post('/api/v1/plugins/install/github-release', {
          'repo': 'acme/plugin',
        }),
        () => gitHubClient(archive: pluginArchive(permissions: ['log'])),
      );

      await http.runWithClient(
        () => post('/api/v1/plugins/update'),
        () => gitHubClient(
          tag: 'v1.1.0',
          archive: pluginArchive(
            version: '1.1.0',
            permissions: ['log', 'proxy.decent_api'],
          ),
        ),
      );

      final listed = await listedPlugin();
      expect(listed['version'], '1.0.0');
      expect(listed['pendingUpdate']['version'], '1.1.0');
      expect(listed['pendingUpdate']['addedPermissions'], ['proxy.decent_api']);

      final approved = await http.runWithClient(
        () => post('/api/v1/plugins/$id/update/approve'),
        () => gitHubClient(
          tag: 'v1.1.0',
          archive: pluginArchive(
            version: '1.1.0',
            permissions: ['log', 'proxy.decent_api'],
          ),
        ),
      );

      expect(approved.statusCode, 200);
      final after = await listedPlugin();
      expect(after['version'], '1.1.0');
      expect(after['pendingUpdate'], isNull);
    });

    test('approving without a pending update is a conflict', () async {
      await http.runWithClient(
        () => post('/api/v1/plugins/install/github-release', {
          'repo': 'acme/plugin',
        }),
        gitHubClient,
      );

      final res = await post('/api/v1/plugins/$id/update/approve');
      expect(res.statusCode, 409);
    });

    test('approving an unknown plugin is a 404', () async {
      final res = await post('/api/v1/plugins/nope.reaplugin/update/approve');
      expect(res.statusCode, 404);
    });
  });
}
