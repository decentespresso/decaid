import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_settings_service.dart';
import '../plugins/plugin_test_helpers.dart';

class _Store implements CredentialStore {
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

List<int> _skinArchive() {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'skin/skin-manifest.json',
        jsonEncode({'id': 'skin', 'name': 'Skin', 'version': '1.0.0'}),
      ),
    )
    ..addFile(ArchiveFile.string('skin/index.html', '<html></html>'));
  return ZipEncoder().encode(archive);
}

List<int> _pluginArchive() {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'repo-main/manifest.json',
        jsonEncode({
          'id': 'integration.reaplugin',
          'author': 'Test',
          'name': 'Integration',
          'description': 'Integration',
          'version': '1.0.0',
          'apiVersion': 1,
          'permissions': <String>[],
          'settings': <String, dynamic>{},
          'api': <Object>[],
        }),
      ),
    )
    ..addFile(
      ArchiveFile.string('repo-main/plugin.js', 'function createPlugin() {}'),
    );
  return ZipEncoder().encode(archive);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shared provider credentials live metadata API and not archives',
    () async {
      SharedPreferences.setMockInitialValues({});
      final tempRoot = await Directory.systemTemp.createTemp('pat-app-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => tempRoot.path,
          );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });
      final credentials = GithubCredentialProvider(store: _Store());
      await credentials.save('pat-one');
      final settings = SettingsController(MockSettingsService());
      await settings.loadSettings();
      final webUiDir = await Directory.systemTemp.createTemp('pat-webui-');
      final anonymousWebUiDir = await Directory.systemTemp.createTemp(
        'pat-webui-anon-',
      );
      addTearDown(() async {
        if (webUiDir.existsSync()) await webUiDir.delete(recursive: true);
        if (anonymousWebUiDir.existsSync()) {
          await anonymousWebUiDir.delete(recursive: true);
        }
      });
      final webStorage = WebUIStorage(settings, credentials: credentials)
        ..debugInitWithWebUIDir(webUiDir);
      final pluginLoader = PluginLoaderService(
        kvStore: FakeKeyValueStoreService(),
      );
      await pluginLoader.initialize();
      final pluginService = PluginSourceService(
        pluginLoader,
        credentials: credentials,
      );
      final seen = <http.BaseRequest>[];
      final client = MockClient((request) async {
        seen.add(request);
        final url = request.url;
        if (url.host == 'api.github.com') {
          expect(
            request.headers['authorization'],
            credentials.current.authorizationHeader,
            reason: url.toString(),
          );
          if (url.path.contains('/commits/')) {
            return http.Response(jsonEncode({'sha': 'commit-one'}), 200);
          }
          if (url.path.contains('/releases/latest')) {
            if (url.path.contains('skin')) {
              return http.Response(
                jsonEncode({
                  'name': 'Skin',
                  'tag_name': 'v1.0.0',
                  'assets': [
                    {
                      'name': 'skin.zip',
                      'browser_download_url': 'https://github.com/acme/skin/releases/download/v1/skin.zip',
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'tag_name': 'v1.0.0',
                'assets': [
                  {
                    'name': 'plugin.zip',
                    'browser_download_url': 'https://github.com/acme/plugin/releases/download/v1/plugin.zip',
                  },
                ],
              }),
              200,
            );
          }
          if (url.path.endsWith('/releases')) {
            return http.Response(
              jsonEncode([
                {
                  'tag_name': 'v1.1.0',
                  'name': 'App',
                  'body': '',
                  'prerelease': false,
                  'assets': [
                    {
                      'name': 'app.apk',
                      'browser_download_url': 'https://github.com/acme/app/releases/download/v1/app.apk',
                    },
                  ],
                },
              ]),
              200,
            );
          }
        }
        expect(request.headers.containsKey('authorization'), isFalse);
        if (url.path.contains('skin.zip')) {
          return http.Response.bytes(_skinArchive(), 200);
        }
        if (url.path.contains('plugin.zip') || url.path.contains('/archive/')) {
          return http.Response.bytes(_pluginArchive(), 200);
        }
        return http.Response.bytes([], 200);
      });

      final updater = AndroidUpdater(
        owner: 'acme',
        repo: 'app',
        httpClient: client,
        credentials: credentials,
      );
      final update = await updater.checkForUpdate('1.0.0');
      expect(update?.version, '1.1.0');
      expect(seen.first.headers['authorization'], 'Bearer pat-one');

      await http.runWithClient(
        () => webStorage.installFromGitHubRelease('acme/skin'),
        () => client,
      );
      expect(webStorage.getSkin('skin'), isNotNull);

      await http.runWithClient(
        () => pluginService.installFromGitHubRelease('acme/plugin'),
        () => client,
      );
      await http.runWithClient(
        () => pluginService.installFromGitHubBranch(
          'acme/plugin-branch',
          branch: 'main',
        ),
        () => client,
      );
      expect(
        seen.where((request) => request.url.host == 'github.com'),
        isNotEmpty,
      );

      await credentials.save('pat-two');
      await updater.checkForUpdate('1.0.0');
      expect(seen.last.headers['authorization'], 'Bearer pat-two');

      await credentials.remove();
      final anonymousSettings = SettingsController(MockSettingsService());
      await anonymousSettings.loadSettings();
      final anonymousStorage = WebUIStorage(
        anonymousSettings,
        credentials: credentials,
      )..debugInitWithWebUIDir(anonymousWebUiDir);
      await http.runWithClient(
        () => anonymousStorage.installFromGitHubRelease('acme/skin-anon'),
        () => client,
      );
      expect(seen.last.headers.containsKey('authorization'), isFalse);

      updater.dispose();
      await pluginLoader.dispose();
    },
  );
}
