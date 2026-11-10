import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/util/remote_update_exception.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginSourceService bundled plugin sources', () {
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
      for (final plugin in loader.availablePlugins) {
        await loader.removePlugin(plugin.id);
      }
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

      void writeHistoricalPendingUpdate(String version) {
        final source = service.sourceFor(dye2Id)!;
        sourceFile(dye2Id).writeAsStringSync(
          jsonEncode(
            source
                .copyWith(
                  pendingUpdate: PluginPendingUpdate(
                    version: version,
                    releaseTag: 'v$version',
                    addedPermissions: ['log'],
                    detectedAt: DateTime.utc(2024, 1, 1),
                  ),
                )
                .toJson(),
          ),
        );
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
          writeHistoricalPendingUpdate('0.2.0');

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
          writeHistoricalPendingUpdate('0.3.0');

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

    group('bundled plugin permission updates', () {
      const bundledId = 'settings.reaplugin';

      Set<String> loaderPermissions() => loader
          .getPluginManifest(bundledId)!
          .permissions
          .map((permission) => permission.wireName)
          .toSet();

      Set<String> diskPermissions() => (jsonDecode(
        File('${tempDir.path}/plugins/$bundledId/manifest.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>)['permissions'].cast<String>().toSet();

      test(
        'bundled release additions from an unrelated repository wait',
        () async {
          await http.runWithClient(
            () => service.installFromGitHubRelease('acme/settings'),
            () => gitHubClient(
              releaseArchive: pluginArchive(
                pluginId: bundledId,
                permissions: ['log'],
              ),
            ),
          );

          await http.runWithClient(
            () => service.updateAllPlugins(),
            () => gitHubClient(
              tag: 'v1.1.0',
              releaseArchive: pluginArchive(
                pluginId: bundledId,
                version: '1.1.0',
                permissions: ['log', 'proxy.decent_api'],
              ),
            ),
          );

          expect(loader.getPluginManifest(bundledId)!.version, '1.0.0');
          expect(loaderPermissions(), {'log'});
          expect(diskPermissions(), {'log'});
          final source = service.sourceFor(bundledId)!;
          expect(source.releaseTag, 'v1.0.0');
          expect(source.pendingUpdate?.addedPermissions, ['proxy.decent_api']);
        },
      );

      test(
        'bundled release equal permissions apply without pending approval',
        () async {
          await http.runWithClient(
            () => service.installFromGitHubRelease('acme/settings'),
            () => gitHubClient(
              releaseArchive: pluginArchive(
                pluginId: bundledId,
                permissions: ['log'],
              ),
            ),
          );

          await http.runWithClient(
            () => service.updateAllPlugins(),
            () => gitHubClient(
              tag: 'v1.1.0',
              releaseArchive: pluginArchive(
                pluginId: bundledId,
                version: '1.1.0',
                permissions: ['log'],
              ),
            ),
          );

          expect(loader.getPluginManifest(bundledId)!.version, '1.1.0');
          expect(loaderPermissions(), {'log'});
          expect(diskPermissions(), {'log'});
          final source = service.sourceFor(bundledId)!;
          expect(source.releaseTag, 'v1.1.0');
          expect(source.pendingUpdate, isNull);
        },
      );

      test(
        'bundled release reduced permissions apply without pending approval',
        () async {
          await http.runWithClient(
            () => service.installFromGitHubRelease('acme/settings'),
            () => gitHubClient(
              releaseArchive: pluginArchive(
                pluginId: bundledId,
                permissions: ['log', 'proxy.decent_api'],
              ),
            ),
          );

          await http.runWithClient(
            () => service.updateAllPlugins(),
            () => gitHubClient(
              tag: 'v1.1.0',
              releaseArchive: pluginArchive(
                pluginId: bundledId,
                version: '1.1.0',
                permissions: ['log'],
              ),
            ),
          );

          expect(loader.getPluginManifest(bundledId)!.version, '1.1.0');
          expect(loaderPermissions(), {'log'});
          expect(diskPermissions(), {'log'});
          final source = service.sourceFor(bundledId)!;
          expect(source.releaseTag, 'v1.1.0');
          expect(source.pendingUpdate, isNull);
        },
      );

      test('bundled branch additions always wait for approval', () async {
        await http.runWithClient(
          () => service.installFromGitHubBranch('acme/settings'),
          () => gitHubClient(
            commit: 'first',
            branchArchive: pluginArchive(
              pluginId: bundledId,
              permissions: ['log'],
            ),
          ),
        );

        await http.runWithClient(
          () => service.updateAllPlugins(),
          () => gitHubClient(
            commit: 'second',
            branchArchive: pluginArchive(
              pluginId: bundledId,
              version: '1.1.0',
              permissions: ['log', 'proxy.decent_api'],
            ),
          ),
        );

        expect(loader.getPluginManifest(bundledId)!.version, '1.0.0');
        expect(loaderPermissions(), {'log'});
        expect(diskPermissions(), {'log'});
        final source = service.sourceFor(bundledId)!;
        expect(source.commit, 'first');
        expect(source.pendingUpdate?.addedPermissions, ['proxy.decent_api']);
      });

      test(
        'bundled branch equal permissions apply without pending approval',
        () async {
          await http.runWithClient(
            () => service.installFromGitHubBranch('acme/settings'),
            () => gitHubClient(
              commit: 'first',
              branchArchive: pluginArchive(
                pluginId: bundledId,
                permissions: ['log'],
              ),
            ),
          );

          await http.runWithClient(
            () => service.updateAllPlugins(),
            () => gitHubClient(
              commit: 'second',
              branchArchive: pluginArchive(
                pluginId: bundledId,
                version: '1.1.0',
                permissions: ['log'],
              ),
            ),
          );

          expect(loader.getPluginManifest(bundledId)!.version, '1.1.0');
          expect(loaderPermissions(), {'log'});
          expect(diskPermissions(), {'log'});
          final source = service.sourceFor(bundledId)!;
          expect(source.commit, 'second');
          expect(source.pendingUpdate, isNull);
        },
      );

      test(
        'bundled branch reduced permissions apply without pending approval',
        () async {
          await http.runWithClient(
            () => service.installFromGitHubBranch('acme/settings'),
            () => gitHubClient(
              commit: 'first',
              branchArchive: pluginArchive(
                pluginId: bundledId,
                permissions: ['log', 'proxy.decent_api'],
              ),
            ),
          );

          await http.runWithClient(
            () => service.updateAllPlugins(),
            () => gitHubClient(
              commit: 'second',
              branchArchive: pluginArchive(
                pluginId: bundledId,
                version: '1.1.0',
                permissions: ['log'],
              ),
            ),
          );

          expect(loader.getPluginManifest(bundledId)!.version, '1.1.0');
          expect(loaderPermissions(), {'log'});
          expect(diskPermissions(), {'log'});
          final source = service.sourceFor(bundledId)!;
          expect(source.commit, 'second');
          expect(source.pendingUpdate, isNull);
        },
      );
    });

    test('a failed install leaves the previous version running', () async {
      await http.runWithClient(
        () => service.installFromGitHubRelease('acme/plugin'),
        gitHubClient,
      );
      await loader.enablePlugin(id);

      await expectLater(
        http.runWithClient(
          () => service.updateAllPlugins(),
          () => gitHubClient(
            tag: 'v1.1.0',
            releaseArchive: makeArchive({
              'manifest.json': jsonEncode(manifestJson(id, version: '1.1.0')),
              'plugin.js':
                  'function createPlugin() { throw new Error("boom"); }',
            }),
          ),
        ),
        throwsA(isA<RemoteUpdateException>()),
      );

      expect(loader.isPluginLoaded(id), isTrue);
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
      expect(service.sourceFor(id)!.releaseTag, 'v1.0.0');
      expect(service.sourceFor(id)!.lastError, isNotNull);
    });

    group('bundled permission provenance', () {
      const bundledId = 'settings.reaplugin';
      const canonicalRepo = 'decentespresso/settings';
      late PluginSourceService provenanceService;

      setUp(() {
        provenanceService = PluginSourceService(
          loader,
          canonicalBundledRepos: const {bundledId: canonicalRepo},
        );
      });

      Future<void> installFrom(String repo) => http.runWithClient(
        () => provenanceService.installFromGitHubRelease(repo),
        () => gitHubClient(
          releaseArchive: pluginArchive(
            pluginId: bundledId,
            permissions: const ['log'],
          ),
        ),
      );

      Future<void> updateTo(List<String> permissions) => http.runWithClient(
        () => provenanceService.updateAllPlugins(),
        () => gitHubClient(
          tag: 'v1.1.0',
          releaseArchive: pluginArchive(
            pluginId: bundledId,
            version: '1.1.0',
            permissions: permissions,
          ),
        ),
      );

      test(
        'canonical repository addition within the bundle is approved',
        () async {
          await installFrom(canonicalRepo);
          await updateTo(const ['log', 'api']);

          expect(loader.getPluginManifest(bundledId)!.version, '1.1.0');
          expect(provenanceService.sourceFor(bundledId)!.pendingUpdate, isNull);
          final diskManifest = jsonDecode(
            File('${loader.getPluginDirectory(bundledId)}/manifest.json')
                .readAsStringSync(),
          ) as Map<String, dynamic>;
          expect(diskManifest['permissions'], unorderedEquals(['log', 'api']));
        },
      );

      test('canonical repository addition beyond the bundle waits', () async {
        await installFrom(canonicalRepo);
        await updateTo(const ['log', 'network.tcp']);

        expect(loader.getPluginManifest(bundledId)!.version, '1.0.0');
        final pending = provenanceService.sourceFor(bundledId)!.pendingUpdate;
        expect(pending, isNotNull);
        expect(pending!.addedPermissions, ['network.tcp']);
      });

      test(
        'unrelated repository addition waits even for a bundled id',
        () async {
          await installFrom('acme/settings');
          await updateTo(const ['log', 'api']);

          expect(loader.getPluginManifest(bundledId)!.version, '1.0.0');
          final pending = provenanceService.sourceFor(bundledId)!.pendingUpdate;
          expect(pending, isNotNull);
          expect(pending!.addedPermissions, ['api']);
        },
      );

      test(
        'branch source addition waits even on the canonical repository',
        () async {
          await http.runWithClient(
            () => provenanceService.installFromGitHubBranch(canonicalRepo),
            () => gitHubClient(
              branchArchive: pluginArchive(
                pluginId: bundledId,
                permissions: const ['log'],
              ),
            ),
          );

          await http.runWithClient(
            () => provenanceService.updateAllPlugins(),
            () => gitHubClient(
              commit: 'commit-2',
              branchArchive: pluginArchive(
                pluginId: bundledId,
                version: '1.1.0',
                permissions: const ['log', 'api'],
              ),
            ),
          );

          expect(loader.getPluginManifest(bundledId)!.version, '1.0.0');
          final pending = provenanceService.sourceFor(bundledId)!.pendingUpdate;
          expect(pending, isNotNull);
          expect(pending!.addedPermissions, ['api']);
        },
      );
    });
  });
}
