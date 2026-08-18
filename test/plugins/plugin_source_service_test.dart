import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_package.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginSourceService', () {
    late Directory tempDir;
    late PluginLoaderService loader;
    late PluginSourceService service;

    const id = 'managed.reaplugin';

    Map<String, dynamic> manifestJson(
      String pluginId, {
      String version = '1.0.0',
      List<String> permissions = const [],
    }) => {
      'id': pluginId,
      'author': 'Test',
      'name': 'Test plugin',
      'description': 'Test plugin',
      'version': version,
      'apiVersion': 1,
      'permissions': permissions,
      'settings': <String, dynamic>{},
      'api': <Object>[],
    };

    String pluginJs(String pluginId, {String marker = ''}) =>
        '''
// $marker
function createPlugin() {
  return { id: "$pluginId", onLoad() {} };
}
''';

    List<int> makeArchive(
      Map<String, String> files, {
      String prefix = 'repo-main/',
    }) {
      final archive = Archive();
      files.forEach((path, content) {
        archive.addFile(ArchiveFile.string('$prefix$path', content));
      });
      return ZipEncoder().encode(archive);
    }

    List<int> pluginArchive({
      String pluginId = id,
      String version = '1.0.0',
      List<String> permissions = const [],
      String marker = '',
      String prefix = 'repo-main/',
    }) => makeArchive({
      'manifest.json': jsonEncode(
        manifestJson(pluginId, version: version, permissions: permissions),
      ),
      'plugin.js': pluginJs(pluginId, marker: marker),
    }, prefix: prefix);

    String releaseJson(String tag, List<String> assetNames) => jsonEncode({
      'tag_name': tag,
      'name': tag,
      'assets': [
        for (final name in assetNames)
          {
            'name': name,
            'browser_download_url': 'https://example.test/assets/$name',
          },
      ],
    });

    MockClient gitHubClient({
      String tag = 'v1.0.0',
      List<String> assets = const ['plugin.zip'],
      List<int>? releaseArchive,
      String commit = 'commit-1',
      List<int>? branchArchive,
    }) {
      return MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/releases/latest') || url.endsWith('/releases')) {
          final body = releaseJson(tag, assets);
          return http.Response(
            url.endsWith('/releases') ? '[$body]' : body,
            200,
          );
        }
        if (url.contains('/commits/')) {
          return http.Response(jsonEncode({'sha': commit}), 200);
        }
        if (url.startsWith('https://example.test/assets/')) {
          return http.Response.bytes(releaseArchive ?? pluginArchive(), 200);
        }
        if (url.contains('/archive/refs/heads/')) {
          return http.Response.bytes(branchArchive ?? pluginArchive(), 200);
        }
        return http.Response('not found: $url', 404);
      });
    }

    File sourceFile(String pluginId) =>
        File('${tempDir.path}/plugins/$pluginId/.rea_source.json');

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('plugin_source_service');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tempDir.path,
          );
      loader = PluginLoaderService(kvStore: FakeKeyValueStoreService());
      await loader.initialize();
      service = PluginSourceService(loader);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await loader.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('installs from a GitHub release and records provenance', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        gitHubClient,
      );

      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      final source = service.sourceFor(id)!;
      expect(source.kind, PluginSourceKind.githubRelease);
      expect(source.repo, 'acme/plugin');
      expect(source.releaseTag, 'v1.0.0');
      expect(source.installedAt, isNotNull);
      expect(source.lastChecked, isNotNull);
    });

    test('rejects a release tag that is not X.Y.Z or vX.Y.Z', () async {
      await expectLater(
        http.runWithClient(
          () => service.installFromGitHubRelease('acme/plugin'),
          () => gitHubClient(tag: 'release-2026'),
        ),
        throwsA(
          isA<PluginPackageException>().having(
            (e) => e.message,
            'message',
            contains('X.Y.Z'),
          ),
        ),
      );
      expect(loader.getPluginManifest(id), isNull);
    });

    test('rejects a release tag that disagrees with the manifest', () async {
      await expectLater(
        http.runWithClient(
          () => service.installFromGitHubRelease('acme/plugin'),
          () => gitHubClient(tag: 'v2.0.0'),
        ),
        throwsA(
          isA<PluginPackageException>().having(
            (e) => e.message,
            'message',
            contains('does not match manifest version'),
          ),
        ),
      );
    });

    test('accepts a tag without the v prefix', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        () => gitHubClient(tag: '1.0.0'),
      );

      expect(service.sourceFor(id)?.releaseTag, '1.0.0');
    });

    test(
      'requires an explicit asset when a release has several zips',
      () async {
        await expectLater(
          http.runWithClient(
            () => service.installFromGitHubRelease('acme/plugin'),
            () => gitHubClient(assets: ['one.zip', 'two.zip']),
          ),
          throwsA(
            isA<PluginPackageException>().having(
              (e) => e.message,
              'message',
              contains('name the one to install'),
            ),
          ),
        );

        await http.runWithClient(
          () => service.installFromGitHubRelease(
            'acme/plugin',
            assetName: 'two.zip',
          ),
          () => gitHubClient(assets: ['one.zip', 'two.zip']),
        );
        expect(service.sourceFor(id)?.assetName, 'two.zip');
      },
    );

    test('installs from a GitHub branch and records the commit', () async {
      await http.runWithClient(
        () => service.installFromGitHubBranch('acme/plugin', branch: 'dev'),
        () => gitHubClient(commit: 'abc123'),
      );

      final source = service.sourceFor(id)!;
      expect(source.kind, PluginSourceKind.githubBranch);
      expect(source.branch, 'dev');
      expect(source.commit, 'abc123');
    });

    test('branch update follows the commit, not the version', () async {
      await http.runWithClient(
        () => service.installFromGitHubBranch('acme/plugin'),
        () => gitHubClient(commit: 'first'),
      );

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          commit: 'second',
          branchArchive: pluginArchive(marker: 'v2 content'),
        ),
      );

      expect(service.sourceFor(id)?.commit, 'second');
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(
        File('${tempDir.path}/plugins/$id/plugin.js').readAsStringSync(),
        contains('v2 content'),
      );
    });

    test('an unchanged commit only moves lastChecked', () async {
      await http.runWithClient(
        () => service.installFromGitHubBranch('acme/plugin'),
        () => gitHubClient(commit: 'same'),
      );
      final before = service.sourceFor(id)!.lastChecked!;

      await Future.delayed(const Duration(milliseconds: 5));
      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(commit: 'same'),
      );

      final after = service.sourceFor(id)!;
      expect(after.commit, 'same');
      expect(after.lastChecked!.isAfter(before), isTrue);
    });

    test('a release update with reduced permissions installs', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        () => gitHubClient(
          releaseArchive: pluginArchive(permissions: ['log', 'api']),
        ),
      );

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          tag: 'v1.1.0',
          releaseArchive: pluginArchive(version: '1.1.0', permissions: ['log']),
        ),
      );

      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(service.sourceFor(id)?.pendingUpdate, isNull);
    });

    test('an added permission blocks the automatic update', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        () => gitHubClient(releaseArchive: pluginArchive(permissions: ['log'])),
      );

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          tag: 'v1.1.0',
          releaseArchive: pluginArchive(
            version: '1.1.0',
            permissions: ['log', 'proxy.decent_api'],
          ),
        ),
      );

      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      final pending = service.sourceFor(id)!.pendingUpdate!;
      expect(pending.version, '1.1.0');
      expect(pending.releaseTag, 'v1.1.0');
      expect(pending.addedPermissions, ['proxy.decent_api']);
    });

    test('approving a pending update installs it', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        () => gitHubClient(releaseArchive: pluginArchive(permissions: ['log'])),
      );
      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          tag: 'v1.1.0',
          releaseArchive: pluginArchive(
            version: '1.1.0',
            permissions: ['log', 'proxy.decent_api'],
          ),
        ),
      );

      await http.runWithClient(
        () => service.approvePendingUpdate(id),
        () => gitHubClient(
          tag: 'v1.1.0',
          releaseArchive: pluginArchive(
            version: '1.1.0',
            permissions: ['log', 'proxy.decent_api'],
          ),
        ),
      );

      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(service.sourceFor(id)?.pendingUpdate, isNull);
    });

    test('approving without a pending update is an error', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        gitHubClient,
      );

      await expectLater(
        service.approvePendingUpdate(id),
        throwsA(isA<PluginApprovalRequiredException>()),
      );
    });

    test('a running plugin is restarted on the new version', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        gitHubClient,
      );
      await loader.enablePlugin(id);

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          tag: 'v1.1.0',
          releaseArchive: pluginArchive(version: '1.1.0'),
        ),
      );

      expect(loader.isPluginLoaded(id), isTrue);
      expect(await loader.shouldAutoLoad(id), isTrue);
      expect(loader.getPluginManifest(id)?.version, '1.1.0');
    });

    test('a disabled plugin stays unloaded across an update', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        gitHubClient,
      );

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          tag: 'v1.1.0',
          releaseArchive: pluginArchive(version: '1.1.0'),
        ),
      );

      expect(loader.isPluginLoaded(id), isFalse);
      expect(await loader.shouldAutoLoad(id), isFalse);
    });

    test('settings survive an update', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        () => gitHubClient(
          releaseArchive: makeArchive({
            'manifest.json': jsonEncode({
              ...manifestJson(id),
              'settings': {
                'Token': {'type': 'string'},
              },
            }),
            'plugin.js': pluginJs(id),
          }),
        ),
      );
      await loader.savePluginSettings(id, {'Token': 'abc'});

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          tag: 'v1.1.0',
          releaseArchive: makeArchive({
            'manifest.json': jsonEncode({
              ...manifestJson(id, version: '1.1.0'),
              'settings': {
                'Token': {'type': 'string'},
              },
            }),
            'plugin.js': pluginJs(id),
          }),
        ),
      );

      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(await loader.pluginSettings(id), containsPair('Token', 'abc'));
    });

    test('one plugin failing does not stop the others', () async {
      await http.runWithClient(
        () => service.installFromGitHubBranch('broken/plugin'),
        () => gitHubClient(commit: 'first'),
      );
      await http.runWithClient(
        () => service.installFromGitHubBranch('good/plugin'),
        () => gitHubClient(
          commit: 'first',
          branchArchive: pluginArchive(pluginId: 'other.reaplugin'),
        ),
      );

      await http.runWithClient(() => service.updateAllPlugins(), () {
        return MockClient((request) async {
          final url = request.url.toString();
          if (url.contains('broken/plugin')) {
            return http.Response('boom', 500);
          }
          if (url.contains('/commits/')) {
            return http.Response(jsonEncode({'sha': 'second'}), 200);
          }
          return http.Response.bytes(
            pluginArchive(pluginId: 'other.reaplugin', marker: 'fresh'),
            200,
          );
        });
      });

      expect(service.sourceFor(id)!.lastError, isNotNull);
      expect(service.sourceFor(id)!.commit, 'first');
      expect(service.sourceFor('other.reaplugin')!.commit, 'second');
      expect(service.sourceFor('other.reaplugin')!.lastError, isNull);
    });

    test('a local zip install is a snapshot that never auto-updates', () async {
      final zip = File('${tempDir.path}/plugin.zip')
        ..writeAsBytesSync(pluginArchive(prefix: 'wrapper/'));

      await service.installFromZip(zip.path);

      final source = service.sourceFor(id)!;
      expect(source.kind, PluginSourceKind.localZip);
      expect(source.kind.isManaged, isFalse);

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => MockClient(
          (_) async => throw StateError('managed update must not run'),
        ),
      );
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
    });

    test('a flat local zip installs too', () async {
      final zip = File('${tempDir.path}/flat.zip')
        ..writeAsBytesSync(pluginArchive(prefix: ''));

      await service.installFromZip(zip.path);

      expect(loader.getPluginManifest(id)?.version, '1.0.0');
    });

    test('removing a plugin clears its source metadata', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        gitHubClient,
      );
      expect(sourceFile(id).existsSync(), isTrue);

      await loader.removePlugin(id);

      expect(sourceFile(id).existsSync(), isFalse);
      expect(loader.getPluginManifest(id), isNull);
    });

    test('a failed install leaves the previous version running', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        gitHubClient,
      );
      await loader.enablePlugin(id);

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          tag: 'v1.1.0',
          releaseArchive: makeArchive({
            'manifest.json': jsonEncode(manifestJson(id, version: '1.1.0')),
            'plugin.js': 'function createPlugin() { throw new Error("boom"); }',
          }),
        ),
      );

      expect(loader.isPluginLoaded(id), isTrue);
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(service.sourceFor(id)!.releaseTag, 'v1.0.0');
      expect(service.sourceFor(id)!.lastError, isNotNull);
    });
  });
}
