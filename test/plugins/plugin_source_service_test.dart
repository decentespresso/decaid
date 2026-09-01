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
        if (url.contains('/releases/tags/')) {
          return http.Response(releaseJson(url.split('/').last, assets), 200);
        }
        if (url.contains('/commits/')) {
          return http.Response(jsonEncode({'sha': commit}), 200);
        }
        if (url.startsWith('https://example.test/assets/')) {
          return http.Response.bytes(releaseArchive ?? pluginArchive(), 200);
        }
        if (url.contains('/archive/')) {
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

    test('a branch install downloads the commit it records', () async {
      await http.runWithClient(
        () => service.installFromGitHubBranch('acme/plugin'),
        () => MockClient((request) async {
          final url = request.url.toString();
          if (url.contains('/commits/')) {
            return http.Response(jsonEncode({'sha': 'commit-1'}), 200);
          }
          if (url.endsWith('/archive/commit-1.zip')) {
            return http.Response.bytes(pluginArchive(version: '1.0.0'), 200);
          }
          if (url.contains('/archive/refs/heads/')) {
            return http.Response.bytes(pluginArchive(version: '2.0.0'), 200);
          }
          return http.Response('not found: $url', 404);
        }),
      );

      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(service.sourceFor(id)!.commit, 'commit-1');
    });

    test('a branch update downloads the commit it records', () async {
      await http.runWithClient(
        () => service.installFromGitHubBranch('acme/plugin'),
        () => gitHubClient(commit: 'commit-1'),
      );

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => MockClient((request) async {
          final url = request.url.toString();
          if (url.contains('/commits/')) {
            return http.Response(jsonEncode({'sha': 'commit-2'}), 200);
          }
          if (url.endsWith('/archive/commit-2.zip')) {
            return http.Response.bytes(pluginArchive(version: '1.1.0'), 200);
          }
          if (url.contains('/archive/refs/heads/')) {
            return http.Response.bytes(pluginArchive(version: '1.2.0'), 200);
          }
          return http.Response('not found: $url', 404);
        }),
      );

      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(service.sourceFor(id)!.commit, 'commit-2');
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

    test('approval installs the reviewed release, not a newer one', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        () => gitHubClient(releaseArchive: pluginArchive(permissions: ['log'])),
      );
      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          tag: 'v1.1.0',
          assets: ['plugin-1.1.0.zip'],
          releaseArchive: pluginArchive(
            version: '1.1.0',
            permissions: ['log', 'proxy.decent_api'],
          ),
        ),
      );
      expect(service.sourceFor(id)!.pendingUpdate!.releaseTag, 'v1.1.0');

      await http.runWithClient(
        () => service.approvePendingUpdate(id),
        () => MockClient((request) async {
          final url = request.url.toString();
          if (url.contains('/releases/latest')) {
            return http.Response(
              releaseJson('v1.2.0', ['plugin-1.2.0.zip']),
              200,
            );
          }
          if (url.endsWith('/releases/tags/v1.1.0')) {
            return http.Response(
              releaseJson('v1.1.0', ['plugin-1.1.0.zip']),
              200,
            );
          }
          if (url.endsWith('plugin-1.1.0.zip')) {
            return http.Response.bytes(
              pluginArchive(
                version: '1.1.0',
                permissions: ['log', 'proxy.decent_api'],
              ),
              200,
            );
          }
          if (url.endsWith('plugin-1.2.0.zip')) {
            return http.Response.bytes(
              pluginArchive(
                version: '1.2.0',
                permissions: [
                  'log',
                  'proxy.decent_api',
                  'proxy.decent_api.write',
                ],
              ),
              200,
            );
          }
          return http.Response('not found: $url', 404);
        }),
      );

      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      expect(service.sourceFor(id)!.releaseTag, 'v1.1.0');
      expect(service.sourceFor(id)!.pendingUpdate, isNull);
    });

    test('a release re-cut at the approved tag needs a new approval', () async {
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

      await expectLater(
        http.runWithClient(
          () => service.approvePendingUpdate(id),
          () => gitHubClient(
            tag: 'v1.1.0',
            releaseArchive: pluginArchive(
              version: '1.1.0',
              permissions: [
                'log',
                'proxy.decent_api',
                'proxy.decent_api.write',
              ],
            ),
          ),
        ),
        throwsA(isA<PluginApprovalRequiredException>()),
      );

      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(service.sourceFor(id)!.pendingUpdate!.addedPermissions, [
        'proxy.decent_api',
        'proxy.decent_api.write',
      ]);
    });

    test('approval installs the reviewed commit, not the new head', () async {
      await http.runWithClient(
        () => service.installFromGitHubBranch('acme/plugin'),
        () => gitHubClient(commit: 'commit-1'),
      );
      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          commit: 'commit-2',
          branchArchive: pluginArchive(version: '1.1.0', permissions: ['log']),
        ),
      );
      expect(service.sourceFor(id)!.pendingUpdate!.commit, 'commit-2');

      await http.runWithClient(
        () => service.approvePendingUpdate(id),
        () => MockClient((request) async {
          final url = request.url.toString();
          if (url.contains('/commits/')) {
            return http.Response(jsonEncode({'sha': 'commit-3'}), 200);
          }
          if (url.endsWith('/archive/commit-2.zip')) {
            return http.Response.bytes(
              pluginArchive(version: '1.1.0', permissions: ['log']),
              200,
            );
          }
          if (url.contains('/archive/refs/heads/')) {
            return http.Response.bytes(
              pluginArchive(version: '2.0.0', permissions: ['log', 'emit']),
              200,
            );
          }
          return http.Response('not found: $url', 404);
        }),
      );

      expect(loader.getPluginManifest(id)?.version, '1.1.0');
      final source = service.sourceFor(id)!;
      expect(source.commit, 'commit-2');
      expect(source.pendingUpdate, isNull);
    });

    test('a branch commit that lowers the version is refused', () async {
      await http.runWithClient(
        () => service.installFromGitHubBranch('acme/plugin'),
        () => gitHubClient(
          commit: 'commit-1',
          branchArchive: pluginArchive(version: '2.0.0'),
        ),
      );

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          commit: 'commit-2',
          branchArchive: pluginArchive(version: '1.0.0'),
        ),
      );

      expect(loader.getPluginManifest(id)?.version, '2.0.0');
      final source = service.sourceFor(id)!;
      expect(source.commit, 'commit-1');
      expect(source.lastError, isNotNull);
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

    test('an update carrying a different plugin is rejected', () async {
      await http.runWithClient(
        () => service.installFromGitHubBranch('acme/plugin'),
        () => gitHubClient(commit: 'first'),
      );

      await http.runWithClient(
        () => service.updateAllPlugins(),
        () => gitHubClient(
          commit: 'second',
          branchArchive: pluginArchive(pluginId: 'someone-else.reaplugin'),
        ),
      );

      expect(loader.getPluginManifest('someone-else.reaplugin'), isNull);
      final source = service.sourceFor(id)!;
      expect(source.commit, 'first');
      expect(source.lastError, contains('someone-else.reaplugin'));
    });

    group('bundled plugin provenance', () {
      const dye2Id = 'dye2.reaplugin';

      Future<void> bundledUpgrade(String version) => loader.updatePluginSource(
        dye2Id,
        manifestJson: manifestJson(dye2Id, version: version),
        pluginJs: pluginJs(dye2Id),
      );

      Future<void> installBundledCopy({
        String pluginId = dye2Id,
        String version = '0.1.4',
      }) async {
        final staging = Directory('${tempDir.path}/bundled_$pluginId')
          ..createSync(recursive: true);
        File('${staging.path}/manifest.json').writeAsStringSync(
          jsonEncode(manifestJson(pluginId, version: version)),
        );
        File('${staging.path}/plugin.js').writeAsStringSync(pluginJs(pluginId));
        await loader.installPluginPackage(staging);
      }

      test('a freshly installed bundled DYE2 gets its repo', () async {
        await installBundledCopy();
        expect(sourceFile(dye2Id).existsSync(), isFalse);

        service.seedBundledSources();

        final source = service.sourceFor(dye2Id)!;
        expect(source.kind, PluginSourceKind.githubRelease);
        expect(source.repo, 'decentespresso/dye2');
        expect(source.releaseTag, 'v0.1.4');
        expect(source.includePrerelease, isFalse);
        expect(source.assetName, isNull);
      });

      test('bundled shot upload gets its canonical repo', () async {
        const pluginId = 'shot-upload.reaplugin';
        await installBundledCopy(pluginId: pluginId, version: '0.2.1');

        service.seedBundledSources();

        final source = service.sourceFor(pluginId)!;
        expect(source.kind, PluginSourceKind.githubRelease);
        expect(source.repo, 'decentespresso/shot-upload');
        expect(source.releaseTag, 'v0.2.1');
        expect(source.assetName, isNull);
      });

      test('bundled dcamp gets its canonical repo', () async {
        const pluginId = 'dcamp.reaplugin';
        // Must match the bundled manifest version (assets/plugins/dcamp.reaplugin
        // = 0.1.2); initialize() already installed the bundled copy, so a lower
        // version here trips the downgrade guard.
        await installBundledCopy(pluginId: pluginId, version: '0.1.2');

        service.seedBundledSources();

        final source = service.sourceFor(pluginId)!;
        expect(source.kind, PluginSourceKind.githubRelease);
        expect(source.repo, 'decentespresso/decaid-dcamp-plugin');
        expect(source.releaseTag, 'v0.1.2');
        expect(source.assetName, isNull);
      });

      test('an existing DYE2 without metadata is migrated', () async {
        await installBundledCopy();
        expect(service.sourceFor(dye2Id), isNull);

        await http.runWithClient(
          () => service.updateAllPlugins(),
          () => gitHubClient(
            tag: 'v0.1.4',
            releaseArchive: pluginArchive(pluginId: dye2Id),
          ),
        );

        expect(service.sourceFor(dye2Id)?.repo, 'decentespresso/dye2');
      });

      test('the update checker then queries decentespresso/dye2', () async {
        await installBundledCopy();

        final requested = <String>[];
        await http.runWithClient(() => service.updateAllPlugins(), () {
          return MockClient((request) async {
            requested.add(request.url.toString());
            final url = request.url.toString();
            if (url.contains('/releases/latest')) {
              return http.Response(
                releaseJson('v0.2.0', ['dye2.reaplugin-0.2.0.zip']),
                200,
              );
            }
            return http.Response.bytes(
              pluginArchive(pluginId: dye2Id, version: '0.2.0'),
              200,
            );
          });
        });

        expect(
          requested,
          contains(
            'https://api.github.com/repos/decentespresso/dye2/releases/latest',
          ),
        );
        expect(loader.getPluginManifest(dye2Id)?.version, '0.2.0');
        expect(service.sourceFor(dye2Id)?.releaseTag, 'v0.2.0');
      });

      test('seeding realigns the tag after a newer bundled copy', () async {
        await installBundledCopy();
        service.seedBundledSources();
        expect(service.sourceFor(dye2Id)?.releaseTag, 'v0.1.4');

        await bundledUpgrade('0.1.5');
        service.seedBundledSources();

        expect(service.sourceFor(dye2Id)?.releaseTag, 'v0.1.5');
      });

      test(
        'seeding clears a pending update the bundled copy satisfies',
        () async {
          await installBundledCopy();
          service.seedBundledSources();

          await http.runWithClient(
            () => service.updateAllPlugins(),
            () => gitHubClient(
              tag: 'v0.2.0',
              releaseArchive: pluginArchive(
                pluginId: dye2Id,
                version: '0.2.0',
                permissions: ['log'],
              ),
            ),
          );
          expect(service.sourceFor(dye2Id)!.pendingUpdate!.version, '0.2.0');

          await bundledUpgrade('0.2.0');
          service.seedBundledSources();

          final source = service.sourceFor(dye2Id)!;
          expect(source.pendingUpdate, isNull);
          expect(source.releaseTag, 'v0.2.0');
        },
      );

      test(
        'seeding keeps a pending update newer than the bundled copy',
        () async {
          await installBundledCopy();
          service.seedBundledSources();

          await http.runWithClient(
            () => service.updateAllPlugins(),
            () => gitHubClient(
              tag: 'v0.3.0',
              releaseArchive: pluginArchive(
                pluginId: dye2Id,
                version: '0.3.0',
                permissions: ['log'],
              ),
            ),
          );
          expect(service.sourceFor(dye2Id)!.pendingUpdate!.version, '0.3.0');

          await bundledUpgrade('0.2.0');
          service.seedBundledSources();

          final source = service.sourceFor(dye2Id)!;
          expect(source.pendingUpdate!.version, '0.3.0');
          expect(source.releaseTag, 'v0.2.0');
        },
      );

      test('seeding leaves a user-chosen source alone', () async {
        await http.runWithClient(
          () => service.installFromGitHubBranch('someone/dye2-fork'),
          () => gitHubClient(
            commit: 'fork-commit',
            branchArchive: pluginArchive(pluginId: dye2Id),
          ),
        );

        service.seedBundledSources();

        final source = service.sourceFor(dye2Id)!;
        expect(source.kind, PluginSourceKind.githubBranch);
        expect(source.repo, 'someone/dye2-fork');
        expect(source.commit, 'fork-commit');
      });
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
