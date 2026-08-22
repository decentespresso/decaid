import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import 'helpers/mock_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebUIStorage install overwrite semantics', () {
    late Directory tmpRoot;
    late Directory webUIDir;
    late WebUIStorage storage;

    setUp(() async {
      tmpRoot = Directory.systemTemp.createTempSync('webui_storage_test');
      webUIDir = Directory('${tmpRoot.path}/web-ui');

      final settingsController = SettingsController(MockSettingsService());
      await settingsController.loadSettings();
      storage = WebUIStorage(settingsController);
      storage.debugInitWithWebUIDir(webUIDir);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tmpRoot.path,
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
    });

    Directory makeSkinSource(String version) {
      final dir = Directory('${tmpRoot.path}/src_$version');
      dir.createSync(recursive: true);
      File('${dir.path}/skin-manifest.json').writeAsStringSync(
        jsonEncode({
          'id': 'test.skin',
          'name': 'Test Skin',
          'version': version,
        }),
      );
      File('${dir.path}/index.html').writeAsStringSync('<html>$version</html>');
      return dir;
    }

    String installedVersion() {
      final manifest = File('${webUIDir.path}/test.skin/skin-manifest.json');
      final json =
          jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
      return json['version'] as String;
    }

    List<int> makeGitHubArchive() {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'passione-dist/skin-manifest.json',
            jsonEncode({
              'id': 'passione-dist',
              'name': 'Passione',
              'version': '1.0.0',
            }),
          ),
        )
        ..addFile(
          ArchiveFile.string('passione-dist/index.html', '<html></html>'),
        );
      return ZipEncoder().encode(archive);
    }

    test('GitHub branch install persists source metadata', () async {
      final archive = makeGitHubArchive();
      var branchHeadRequests = 0;
      var branchGetRequests = 0;
      late DateTime before;
      late DateTime after;

      await http.runWithClient(
        () async {
          await storage.installFromGitHub('tadelv/passione', branch: 'dist');
          before = storage.getSkin('passione-dist')!.reaMetadata!.lastChecked!;

          await storage.updateAllSkins();
          after = storage.getSkin('passione-dist')!.reaMetadata!.lastChecked!;
        },
        () => MockClient((request) async {
          if (request.url.toString() !=
              'https://github.com/tadelv/passione/archive/refs/heads/dist.zip') {
            return http.Response('', 404);
          }
          if (request.method == 'HEAD') {
            branchHeadRequests++;
            return http.Response('', 200, headers: {'etag': 'branch-etag'});
          }
          branchGetRequests++;
          return http.Response.bytes(archive, 200);
        }),
      );

      expect(branchHeadRequests, 2);
      expect(branchGetRequests, 1);
      expect(after.isAfter(before), isTrue);

      final metadata = storage.getSkin('passione-dist')!.reaMetadata!;
      expect(metadata.sourceUrl, 'github_branch:tadelv/passione@dist');

      final persisted =
          jsonDecode(
                File('${webUIDir.path}/.rea_metadata.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(
        persisted['passione-dist']['sourceUrl'],
        'github_branch:tadelv/passione@dist',
      );
      expect(DateTime.parse(persisted['passione-dist']['lastChecked']), after);
    });

    test('install cleans up temporary directories', () async {
      final archive = makeGitHubArchive();

      await http.runWithClient(
        () => storage.installFromUrl('https://example.com/skin.zip'),
        () => MockClient((request) async {
          return http.Response.bytes(archive, 200);
        }),
      );

      final leftovers = tmpRoot
          .listSync()
          .whereType<Directory>()
          .where(
            (dir) =>
                dir.path.contains('webui_install') ||
                dir.path.contains('webui_extract'),
          )
          .toList();
      expect(leftovers, isEmpty);
    });

    test('URL install persists source metadata; updateAllSkins refreshes on '
        'ETag change', () async {
      final archive = makeGitHubArchive();
      var urlHeadRequests = 0;
      var urlGetRequests = 0;
      var etag = 'url-etag-v1';

      await http.runWithClient(
        () async {
          await storage.installFromUrl('https://example.com/skin.zip');

          final metadata = storage.getSkin('passione-dist')!.reaMetadata!;
          expect(metadata.sourceUrl, 'https://example.com/skin.zip');
          expect(metadata.etag, 'url-etag-v1');
          expect(storage.getSkin('passione-dist')!.isBundled, isFalse);
          expect(urlGetRequests, 1);

          await storage.updateAllSkins();
          expect(urlGetRequests, 1);

          etag = 'url-etag-v2';
          await storage.updateAllSkins();
          expect(urlGetRequests, 2);
          expect(
            storage.getSkin('passione-dist')!.reaMetadata!.etag,
            'url-etag-v2',
          );
        },
        () => MockClient((request) async {
          final url = request.url.toString();
          if (url != 'https://example.com/skin.zip') {
            return http.Response('', 404);
          }
          if (request.method == 'HEAD') {
            urlHeadRequests++;
            return http.Response('', 200, headers: {'etag': etag});
          }
          urlGetRequests++;
          return http.Response.bytes(archive, 200, headers: {'etag': etag});
        }),
      );

      expect(urlHeadRequests, greaterThanOrEqualTo(2));
      final persisted =
          jsonDecode(
                File('${webUIDir.path}/.rea_metadata.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(
        persisted['passione-dist']['sourceUrl'],
        'https://example.com/skin.zip',
      );
    });

    test('GitHub release install tracks release; updateAllSkins picks up new '
        'releases and keeps the skin removable', () async {
      final archive = makeGitHubArchive();
      var apiGets = 0;
      var assetGets = 0;
      var releaseTag = 'v1.0.0';
      Map<String, dynamic> releaseBody() => {
        'tag_name': releaseTag,
        'name': 'Custom Skin $releaseTag',
        'published_at': '2026-01-01T00:00:00Z',
        'assets': [
          {
            'name': 'custom-skin.zip',
            'browser_download_url':
                'https://github.com/acme/custom-skin/releases/download/'
                '$releaseTag/custom-skin.zip',
            'size': 1234,
          },
        ],
      };

      await http.runWithClient(
        () async {
          await storage.installFromGitHubRelease('acme/custom-skin');

          var metadata = storage.getSkin('passione-dist')!.reaMetadata!;
          expect(metadata.sourceUrl, 'github_release:acme/custom-skin@v1.0.0');
          expect(storage.getSkin('passione-dist')!.isBundled, isFalse);
          expect(assetGets, 1);

          await storage.updateAllSkins();
          expect(assetGets, 1);

          releaseTag = 'v1.1.0';
          await storage.updateAllSkins();
          expect(assetGets, 2);
          metadata = storage.getSkin('passione-dist')!.reaMetadata!;
          expect(metadata.sourceUrl, 'github_release:acme/custom-skin@v1.1.0');
          expect(storage.getSkin('passione-dist')!.isBundled, isFalse);
        },
        () => MockClient((request) async {
          final url = request.url.toString();
          if (url ==
              'https://api.github.com/repos/acme/custom-skin/releases/latest') {
            apiGets++;
            return http.Response(jsonEncode(releaseBody()), 200);
          }
          if (url.startsWith(
            'https://github.com/acme/custom-skin/releases/download/',
          )) {
            assetGets++;
            return http.Response.bytes(archive, 200);
          }
          return http.Response('', 404);
        }),
      );

      expect(apiGets, greaterThanOrEqualTo(2));
    });

    test(
      'GitHub release update preserves a specifically selected asset',
      () async {
        final archive = makeGitHubArchive();
        final requestedAssets = <String>[];
        var releaseTag = 'v1.0.0';
        Map<String, dynamic> releaseBody() => {
          'tag_name': releaseTag,
          'name': 'Custom Skin $releaseTag',
          'published_at': '2026-01-01T00:00:00Z',
          'assets': [
            {
              'name': 'first.zip',
              'browser_download_url':
                  'https://github.com/acme/custom-skin/releases/download/'
                  '$releaseTag/first.zip',
              'size': 100,
            },
            {
              'name': 'second.zip',
              'browser_download_url':
                  'https://github.com/acme/custom-skin/releases/download/'
                  '$releaseTag/second.zip',
              'size': 200,
            },
          ],
        };

        await http.runWithClient(
          () async {
            await storage.installFromGitHubRelease(
              'acme/custom-skin',
              assetName: 'second.zip',
            );
            expect(requestedAssets, [
              'https://github.com/acme/custom-skin/releases/download/'
                  'v1.0.0/second.zip',
            ]);
            expect(
              storage.getSkin('passione-dist')!.reaMetadata!.releaseAssetName,
              'second.zip',
            );

            releaseTag = 'v1.1.0';
            await storage.updateAllSkins();
            expect(requestedAssets, [
              'https://github.com/acme/custom-skin/releases/download/'
                  'v1.0.0/second.zip',
              'https://github.com/acme/custom-skin/releases/download/'
                  'v1.1.0/second.zip',
            ]);
            expect(
              storage.getSkin('passione-dist')!.reaMetadata!.releaseAssetName,
              'second.zip',
            );
          },
          () => MockClient((request) async {
            final url = request.url.toString();
            if (url ==
                'https://api.github.com/repos/acme/custom-skin/releases/latest') {
              return http.Response(jsonEncode(releaseBody()), 200);
            }
            if (url.startsWith(
              'https://github.com/acme/custom-skin/releases/download/',
            )) {
              requestedAssets.add(url);
              return http.Response.bytes(archive, 200);
            }
            return http.Response('', 404);
          }),
        );
      },
    );

    test('GitHub release update preserves prerelease tracking', () async {
      final archive = makeGitHubArchive();
      final latestApiGets = <String>[];
      var releaseTag = 'v1.0.0-rc.1';
      Map<String, dynamic> releaseBody() => {
        'tag_name': releaseTag,
        'name': 'Custom Skin $releaseTag',
        'prerelease': true,
        'published_at': '2026-01-01T00:00:00Z',
        'assets': [
          {
            'name': 'custom-skin.zip',
            'browser_download_url':
                'https://github.com/acme/custom-skin/releases/download/'
                '$releaseTag/custom-skin.zip',
            'size': 1234,
          },
        ],
      };

      await http.runWithClient(
        () async {
          await storage.installFromGitHubRelease(
            'acme/custom-skin',
            includePrerelease: true,
          );
          expect(
            storage.getSkin('passione-dist')!.reaMetadata!.includePrerelease,
            isTrue,
          );

          releaseTag = 'v1.1.0-rc.1';
          await storage.updateAllSkins();
          expect(
            latestApiGets.every((u) => u.endsWith('/releases')),
            isTrue,
            reason: 'prerelease updates must use the /releases endpoint',
          );
          expect(
            storage.getSkin('passione-dist')!.reaMetadata!.sourceUrl,
            'github_release:acme/custom-skin@v1.1.0-rc.1',
          );
          expect(
            storage.getSkin('passione-dist')!.reaMetadata!.includePrerelease,
            isTrue,
          );
        },
        () => MockClient((request) async {
          final url = request.url.toString();
          if (url == 'https://api.github.com/repos/acme/custom-skin/releases' ||
              url ==
                  'https://api.github.com/repos/acme/custom-skin/releases/latest') {
            latestApiGets.add(url);
            return http.Response(
              url.endsWith('/releases')
                  ? jsonEncode([releaseBody()])
                  : jsonEncode(releaseBody()),
              200,
            );
          }
          if (url.startsWith(
            'https://github.com/acme/custom-skin/releases/download/',
          )) {
            return http.Response.bytes(archive, 200);
          }
          return http.Response('', 404);
        }),
      );
    });

    test('overwriteIfExists:false leaves an existing skin untouched', () async {
      await storage.installFromPath(makeSkinSource('0.1.33').path);
      expect(installedVersion(), '0.1.33');

      await storage.installFromPath(
        makeSkinSource('0.1.31').path,
        overwriteIfExists: false,
      );
      expect(installedVersion(), '0.1.33');
    });

    test('overwriteIfExists:true replaces an existing skin', () async {
      await storage.installFromPath(makeSkinSource('0.1.31').path);
      expect(installedVersion(), '0.1.31');

      await storage.installFromPath(makeSkinSource('0.1.33').path);
      expect(installedVersion(), '0.1.33');
    });

    test('overwriteIfExists:false still installs when absent', () async {
      await storage.installFromPath(
        makeSkinSource('0.1.31').path,
        overwriteIfExists: false,
      );
      expect(installedVersion(), '0.1.31');
    });
  });
}
