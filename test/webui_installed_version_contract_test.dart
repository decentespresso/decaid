import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';
import 'package:yaml/yaml.dart';

import 'helpers/mock_settings_service.dart';

const _sourcesAsset = 'skin_sources.json';
const _bundledManifestAsset = 'assets/bundled_skins/manifest.json';

const _configuredSources = [
  {'type': 'github_release', 'repo': _configuredRepository},
];
const _configuredRepository = 'fixture/configured';

const _releaseRepository = 'acme/release-skin';
const _releaseApiUrl =
    'https://api.github.com/repos/acme/release-skin/releases/latest';
const _branchUrl =
    'https://github.com/acme/branch-skin/archive/refs/heads/dist.zip';
const _configuredApiUrl =
    'https://api.github.com/repos/fixture/configured/releases/latest';

const _skinManifestUrl = 'https://example.test/skin-manifest-skin.zip';
const _manifestUrl = 'https://example.test/manifest-skin.zip';

Uint8List _skinZip({
  required String id,
  required String name,
  String? version,
  String manifestName = 'skin-manifest.json',
}) {
  final manifest = <String, dynamic>{'id': id, 'name': name};
  if (version != null) manifest['version'] = version;
  final archive = Archive()
    ..addFile(ArchiveFile.string('$id/$manifestName', jsonEncode(manifest)))
    ..addFile(ArchiveFile.string('$id/index.html', '<html>$name</html>'));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, dynamic> _releaseJson({
  required String repository,
  required String tag,
  required String assetName,
}) => {
  'tag_name': tag,
  'name': 'Custom $tag',
  'published_at': '2026-01-01T00:00:00Z',
  'assets': [
    {
      'name': assetName,
      'browser_download_url':
          'https://github.com/$repository/releases/download/$tag/$assetName',
      'size': 1234,
    },
  ],
};

Future<Map<String, dynamic>> _getJson(Handler handler, String path) async {
  final response = await handler(
    Request('GET', Uri.parse('http://localhost$path')),
  );
  final text = await response.readAsString();
  expect(response.statusCode, 200, reason: '$path returned $text');
  return jsonDecode(text) as Map<String, dynamic>;
}

Handler _buildHandler(WebUIStorage storage) {
  final webUIHandler = WebUIHandler(storage: storage, service: WebUIService());
  final app = Router().plus;
  webUIHandler.addRoutes(app);
  return app.call;
}

Future<WebUIStorage> _openStorage(Directory root) async {
  final storage = WebUIStorage(
    SettingsController(MockSettingsService()),
    webUIDir: root,
  );
  await storage.initialize(downloadRemote: false);
  return storage;
}

final _networkAttempts = <String>[];

Future<T> _withoutNetwork<T>(Future<T> Function() body) {
  return http.runWithClient(
    body,
    () => MockClient((request) async {
      _networkAttempts.add(request.url.toString());
      throw StateError(
        'read routes must not reach the network: ${request.url}',
      );
    }),
  );
}

String? _installedManifestVersion(
  Directory root,
  String id, {
  String manifestName = 'skin-manifest.json',
}) {
  final manifest = jsonDecode(
    File('${root.path}/$id/$manifestName').readAsStringSync(),
  ) as Map<String, dynamic>;
  return manifest['version'] as String?;
}

Map<String, String> _snapshot(Directory directory) {
  final entries = <String, String>{};
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    final stat = entity.statSync();
    entries[p.relative(entity.path, from: directory.path)] =
        '${stat.size}|${stat.modified.microsecondsSinceEpoch}|'
        '${base64Encode(entity.readAsBytesSync())}';
  }
  return entries;
}

Map<String, dynamic> _uniqueSkin(List<dynamic> skins, String id) {
  final matches = skins
      .cast<Map<String, dynamic>>()
      .where((skin) => skin['id'] == id)
      .toList();
  expect(matches, hasLength(1), reason: 'expected exactly one "$id" in $skins');
  return matches.single;
}

Map<String, dynamic> _resultFor(Map<String, dynamic> body, String item) {
  final results = (body['results'] as List).cast<Map<String, dynamic>>();
  final matches = results.where((result) => result['item'] == item).toList();
  expect(
    matches,
    hasLength(1),
    reason: 'expected exactly one result for "$item" in $results',
  );
  return matches.single;
}

class _SkinApi {
  _SkinApi(this.storage) : handler = _buildHandler(storage);

  final WebUIStorage storage;
  final Handler handler;

  Future<List<dynamic>> listSkins() async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/webui/skins')),
    );
    final text = await response.readAsString();
    expect(response.statusCode, 200, reason: text);
    return jsonDecode(text) as List<dynamic>;
  }

  Future<Map<String, dynamic>> installedSkin(String id) =>
      _getJson(handler, '/api/v1/webui/skins/$id');

  Future<String> rawSkin(String id) async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/webui/skins/$id')),
    );
    expect(response.statusCode, 200);
    return response.readAsString();
  }

  Future<int> statusOf(String path) async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost$path')),
    );
    await response.readAsString();
    return response.statusCode;
  }

  Future<({int statusCode, Map<String, dynamic> body})> post(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: body == null ? null : jsonEncode(body),
        headers: body == null ? null : {'content-type': 'application/json'},
      ),
    );
    final text = await response.readAsString();
    return (
      statusCode: response.statusCode,
      body: text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  Future<({int statusCode, Map<String, dynamic> body})> updateSkins() =>
      post('/api/v1/webui/skins/update');
}

class _Remote {
  String releaseTag = 'v1.0.0';
  String? releaseVersion = '1.0.0';
  int releaseAssetStatus = 200;

  String branchEtag = 'branch-etag-1';
  String? branchVersion = '0.4.0';
  int branchDownloadStatus = 200;
  bool branchDownloadIsZip = true;

  String configuredTag = 'v1.0.0';
  String? configuredVersion = '1.0.0';

  int requests = 0;
  int branchDownloads = 0;

  MockClient get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    requests++;
    final url = request.url.toString();

    if (url == _releaseApiUrl) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(
            _releaseJson(
              repository: _releaseRepository,
              tag: releaseTag,
              assetName: 'release-skin.zip',
            ),
          ),
        ),
        200,
      );
    }
    if (url ==
        'https://github.com/$_releaseRepository/releases/download/'
            '$releaseTag/release-skin.zip') {
      if (releaseAssetStatus != 200) {
        return http.Response('unavailable', releaseAssetStatus);
      }
      return http.Response.bytes(
        _skinZip(
          id: 'release-skin',
          name: 'Release Skin',
          version: releaseVersion,
        ),
        200,
      );
    }
    if (url == _configuredApiUrl) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(
            _releaseJson(
              repository: _configuredRepository,
              tag: configuredTag,
              assetName: 'configured-skin.zip',
            ),
          ),
        ),
        200,
      );
    }
    if (url ==
        'https://github.com/$_configuredRepository/releases/download/'
            '$configuredTag/configured-skin.zip') {
      return http.Response.bytes(
        _skinZip(
          id: 'configured-skin',
          name: 'Configured Skin',
          version: configuredVersion,
        ),
        200,
      );
    }
    if (url == _branchUrl) {
      if (request.method == 'HEAD') {
        return http.Response('', 200, headers: {'etag': branchEtag});
      }
      branchDownloads++;
      if (branchDownloadStatus != 200) {
        return http.Response('unavailable', branchDownloadStatus);
      }
      if (!branchDownloadIsZip) {
        return http.Response('this is not a zip archive', 200);
      }
      return http.Response.bytes(
        _skinZip(
          id: 'branch-skin',
          name: 'Branch Skin',
          version: branchVersion,
          manifestName: 'manifest.json',
        ),
        200,
        headers: {'etag': branchEtag},
      );
    }
    if (url == _skinManifestUrl) {
      return http.Response.bytes(
        _skinZip(
          id: 'skin-manifest-skin',
          name: 'Skin Manifest Skin',
          version: '1.2.3',
        ),
        200,
      );
    }
    if (url == _manifestUrl) {
      return http.Response.bytes(
        _skinZip(
          id: 'manifest-skin',
          name: 'Manifest Skin',
          version: '2.0.4',
          manifestName: 'manifest.json',
        ),
        200,
      );
    }
    return http.Response('not found: $url', 404);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory tempRoot;

  setUp(() {
    root = Directory.systemTemp.createTempSync('decaid_installed_version');
    tempRoot = Directory.systemTemp.createTempSync(
      'decaid_installed_version_tmp',
    );
    _networkAttempts.clear();
    rootBundle.evict(_sourcesAsset);
    rootBundle.evict(_bundledManifestAsset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final key = const StringCodec().decodeMessage(message);
          final Object? payload;
          switch (key) {
            case _sourcesAsset:
              payload = _configuredSources;
            case _bundledManifestAsset:
              payload = const <String>[];
            default:
              payload = null;
          }
          if (payload == null) return null;
          return ByteData.sublistView(
            Uint8List.fromList(utf8.encode(jsonEncode(payload))),
          );
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempRoot.path,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    rootBundle.evict(_sourcesAsset);
    rootBundle.evict(_bundledManifestAsset);
    root.deleteSync(recursive: true);
    tempRoot.deleteSync(recursive: true);
  });

  test('both read routes report the version from either installed manifest'
      ' filename', () async {
    final remote = _Remote();
    final api = _SkinApi(await _openStorage(root));

    await http.runWithClient(() async {
      final skinManifest = await api.post('/api/v1/webui/skins/install/url', {
        'url': _skinManifestUrl,
      });
      expect(skinManifest.statusCode, 200, reason: '${skinManifest.body}');
      final manifest = await api.post('/api/v1/webui/skins/install/url', {
        'url': _manifestUrl,
      });
      expect(manifest.statusCode, 200, reason: '${manifest.body}');
    }, () => remote.client);

    await _withoutNetwork(() async {
      final listed = _uniqueSkin(await api.listSkins(), 'skin-manifest-skin');
      final single = await api.installedSkin('skin-manifest-skin');

      expect(listed['version'], '1.2.3');
      expect(single['version'], '1.2.3');
      expect(single, listed);
      expect(
        _uniqueSkin(await api.listSkins(), 'manifest-skin')['version'],
        '2.0.4',
      );
      expect((await api.installedSkin('manifest-skin'))['version'], '2.0.4');
    });

    expect(_installedManifestVersion(root, 'skin-manifest-skin'), '1.2.3');
    expect(
      _installedManifestVersion(
        root,
        'manifest-skin',
        manifestName: 'manifest.json',
      ),
      '2.0.4',
    );

    final persisted = jsonDecode(
      File('${root.path}/.rea_metadata.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final diskLastChecked = persisted['skin-manifest-skin']['lastChecked'];
    expect(diskLastChecked, isA<String>());

    await _withoutNetwork(() async {
      final listed = _uniqueSkin(await api.listSkins(), 'skin-manifest-skin');
      final single = await api.installedSkin('skin-manifest-skin');
      final metadata = single['reaMetadata'] as Map<String, dynamic>;
      expect(metadata['sourceUrl'], _skinManifestUrl);
      expect(metadata['lastChecked'], isNotNull);
      expect(metadata['lastChecked'], diskLastChecked);
      expect(
        DateTime.parse(metadata['lastChecked'] as String),
        DateTime.parse(diskLastChecked as String),
        reason: 'lastChecked must be a parseable timestamp equal to disk',
      );
      final listedMetadata = listed['reaMetadata'] as Map<String, dynamic>;
      expect(listedMetadata['lastChecked'], diskLastChecked);
      expect(listedMetadata['lastChecked'], metadata['lastChecked']);
    });

    final raw = await _withoutNetwork(() => api.rawSkin('skin-manifest-skin'));
    expect(
      '"lastChecked"'.allMatches(raw),
      hasLength(1),
      reason: 'lastChecked is serialized once, inside reaMetadata: $raw',
    );
    expect(
      '"lastChecked":"$diskLastChecked"'.allMatches(raw),
      hasLength(1),
      reason: 'the emitted stamp must be the persisted one: $raw',
    );
  });

  test('historical metadata without lastChecked serializes null exactly once'
      ' through both read routes and across a reload', () async {
    final remote = _Remote();
    final api = _SkinApi(await _openStorage(root));

    await http.runWithClient(() async {
      final skinManifest = await api.post('/api/v1/webui/skins/install/url', {
        'url': _skinManifestUrl,
      });
      expect(skinManifest.statusCode, 200, reason: '${skinManifest.body}');
      final release = await api.post(
        '/api/v1/webui/skins/install/github-release',
        {'repo': _releaseRepository},
      );
      expect(release.statusCode, 200, reason: '${release.body}');
    }, () => remote.client);

    final metadataFile = File('${root.path}/.rea_metadata.json');
    final recorded =
        jsonDecode(metadataFile.readAsStringSync()) as Map<String, dynamic>;
    final missingKey = recorded['skin-manifest-skin'] as Map<String, dynamic>;
    expect(missingKey['lastChecked'], isNotNull);
    missingKey.remove('lastChecked');
    final explicitNull = recorded['release-skin'] as Map<String, dynamic>;
    explicitNull['lastChecked'] = null;
    metadataFile.writeAsStringSync(jsonEncode(recorded));

    Future<void> expectNullLastChecked(_SkinApi reader) async {
      final listed = await reader.listSkins();
      for (final id in ['skin-manifest-skin', 'release-skin']) {
        final listedMetadata =
            _uniqueSkin(listed, id)['reaMetadata'] as Map<String, dynamic>;
        expect(listedMetadata.containsKey('lastChecked'), isTrue);
        expect(listedMetadata['lastChecked'], isNull);

        final single = await reader.installedSkin(id);
        final singleMetadata = single['reaMetadata'] as Map<String, dynamic>;
        expect(singleMetadata.containsKey('lastChecked'), isTrue);
        expect(singleMetadata['lastChecked'], isNull);
        expect(singleMetadata, listedMetadata);

        final raw = await reader.rawSkin(id);
        expect(
          '"lastChecked"'.allMatches(raw),
          hasLength(1),
          reason: 'lastChecked is serialized once, inside reaMetadata: $raw',
        );
        expect(
          '"lastChecked":null'.allMatches(raw),
          hasLength(1),
          reason: 'a historical missing or null stamp stays null: $raw',
        );
      }
    }

    await _withoutNetwork(() async {
      await expectNullLastChecked(_SkinApi(await _openStorage(root)));
      await expectNullLastChecked(_SkinApi(await _openStorage(root)));
    });
  });

  test('unknown versions stay null even though the source carries a release'
      ' tag, ETag and commit hash', () async {
    final remote = _Remote()
      ..releaseVersion = null
      ..branchVersion = null;
    final api = _SkinApi(await _openStorage(root));

    await http.runWithClient(() async {
      final release = await api.post(
        '/api/v1/webui/skins/install/github-release',
        {'repo': _releaseRepository},
      );
      expect(release.statusCode, 200, reason: '${release.body}');
      final branch = await api.post(
        '/api/v1/webui/skins/install/github-branch',
        {'repo': 'acme/branch-skin', 'branch': 'dist'},
      );
      expect(branch.statusCode, 200, reason: '${branch.body}');

      final update = await api.updateSkins();
      expect(update.statusCode, 200, reason: '${update.body}');
    }, () => remote.client);

    remote.releaseTag = 'v10.0.0';
    remote.branchEtag = 'branch-etag-2';

    await http.runWithClient(() async {
      final update = await api.updateSkins();
      expect(update.statusCode, 200, reason: '${update.body}');
      expect(_resultFor(update.body, 'release-skin')['status'], 'updated');
      expect(_resultFor(update.body, 'branch-skin')['status'], 'updated');
    }, () => remote.client);

    await _withoutNetwork(() async {
      final releaseSkin = await api.installedSkin('release-skin');
      expect(releaseSkin.containsKey('version'), isTrue);
      expect(releaseSkin['version'], isNull);
      final releaseMetadata =
          releaseSkin['reaMetadata'] as Map<String, dynamic>;
      expect(
        releaseMetadata['sourceUrl'],
        'github_release:acme/release-skin@v10.0.0',
      );
      expect(releaseMetadata['commitHash'], 'v10.0.0');
      expect(releaseMetadata['lastModified'], '2026-01-01T00:00:00Z');
      expect(releaseMetadata['lastChecked'], isNotNull);

      final branchSkin = await api.installedSkin('branch-skin');
      expect(branchSkin.containsKey('version'), isTrue);
      expect(branchSkin['version'], isNull);
      final branchMetadata = branchSkin['reaMetadata'] as Map<String, dynamic>;
      expect(branchMetadata['etag'], 'branch-etag-2');
      expect(branchMetadata['commitHash'], 'branch:dist');

      final releaseListed = _uniqueSkin(await api.listSkins(), 'release-skin');
      expect(releaseListed.containsKey('version'), isTrue);
      expect(releaseListed['version'], isNull);

      final branchListed = _uniqueSkin(await api.listSkins(), 'branch-skin');
      expect(branchListed.containsKey('version'), isTrue);
      expect(branchListed['version'], isNull);
    });
  });

  test('a release update rewrites the installed version for both read routes'
      ' and for a storage reload', () async {
    final remote = _Remote();
    final api = _SkinApi(await _openStorage(root));

    await http.runWithClient(() async {
      final install = await api.post(
        '/api/v1/webui/skins/install/github-release',
        {'repo': _releaseRepository},
      );
      expect(install.statusCode, 200, reason: '${install.body}');
    }, () => remote.client);

    await _withoutNetwork(() async {
      expect((await api.installedSkin('release-skin'))['version'], '1.0.0');
    });

    remote.releaseTag = 'v1.1.0';
    remote.releaseVersion = '1.1.0';

    await http.runWithClient(() async {
      final update = await api.updateSkins();
      expect(update.statusCode, 200, reason: '${update.body}');
      expect(update.body['message'], 'Skin update check completed');
      final result = _resultFor(update.body, 'release-skin');
      expect(result['status'], 'updated');
      expect(result, isNot(contains('error')));

      await _withoutNetwork(() async {
        expect((await api.installedSkin('release-skin'))['version'], '1.1.0');
        expect(
          _uniqueSkin(await api.listSkins(), 'release-skin')['version'],
          '1.1.0',
        );
      });

      final again = await api.updateSkins();
      expect(
        _resultFor(again.body, 'release-skin')['status'],
        'alreadyCurrent',
      );
    }, () => remote.client);

    expect(_installedManifestVersion(root, 'release-skin'), '1.1.0');

    await _withoutNetwork(() async {
      expect((await api.installedSkin('release-skin'))['version'], '1.1.0');
      expect(
        _uniqueSkin(await api.listSkins(), 'release-skin')['version'],
        '1.1.0',
      );
    });

    final reloadedApi = _SkinApi(await _openStorage(root));
    await _withoutNetwork(() async {
      final reloadedSkin = await reloadedApi.installedSkin('release-skin');
      expect(reloadedSkin['version'], '1.1.0');
      expect(
        (reloadedSkin['reaMetadata'] as Map<String, dynamic>)['sourceUrl'],
        'github_release:acme/release-skin@v1.1.0',
      );
      expect(
        _uniqueSkin(await reloadedApi.listSkins(), 'release-skin')['version'],
        '1.1.0',
      );
    });
  });

  test('a branch update rewrites the installed version, keeps an unchanged'
      ' source untouched, and survives a storage reload', () async {
    final remote = _Remote()..branchVersion = '0.4.0';
    final api = _SkinApi(await _openStorage(root));

    await http.runWithClient(() async {
      final install = await api.post(
        '/api/v1/webui/skins/install/github-branch',
        {'repo': 'acme/branch-skin', 'branch': 'dist'},
      );
      expect(install.statusCode, 200, reason: '${install.body}');
    }, () => remote.client);

    await _withoutNetwork(() async {
      final skin = await api.installedSkin('branch-skin');
      expect(skin['version'], '0.4.0');
      expect(
        (skin['reaMetadata'] as Map<String, dynamic>)['sourceUrl'],
        'github_branch:acme/branch-skin@dist',
      );
    });

    await http.runWithClient(() async {
      final update = await api.updateSkins();
      expect(
        _resultFor(update.body, 'branch-skin')['status'],
        'alreadyCurrent',
      );
    }, () => remote.client);
    expect(remote.branchDownloads, 1);

    await _withoutNetwork(() async {
      expect(
        _installedManifestVersion(
          root,
          'branch-skin',
          manifestName: 'manifest.json',
        ),
        '0.4.0',
      );
      expect((await api.installedSkin('branch-skin'))['version'], '0.4.0');
      expect(
        _uniqueSkin(await api.listSkins(), 'branch-skin')['version'],
        '0.4.0',
      );
    });

    remote
      ..branchEtag = 'branch-etag-2'
      ..branchVersion = '0.5.0';

    await http.runWithClient(() async {
      final update = await api.updateSkins();
      expect(_resultFor(update.body, 'branch-skin')['status'], 'updated');
    }, () => remote.client);

    expect(remote.branchDownloads, 2);
    expect(
      _installedManifestVersion(
        root,
        'branch-skin',
        manifestName: 'manifest.json',
      ),
      '0.5.0',
    );

    await _withoutNetwork(() async {
      expect((await api.installedSkin('branch-skin'))['version'], '0.5.0');
      expect(
        _uniqueSkin(await api.listSkins(), 'branch-skin')['version'],
        '0.5.0',
      );
    });

    final reloadedApi = _SkinApi(await _openStorage(root));
    await _withoutNetwork(() async {
      expect(
        (await reloadedApi.installedSkin('branch-skin'))['version'],
        '0.5.0',
      );
      expect(
        (await reloadedApi.installedSkin('branch-skin'))['reaMetadata']['etag'],
        'branch-etag-2',
      );
    });
  });

  test('a failed download or an invalid archive keeps the installed version'
      ' and the installed bytes', () async {
    final remote = _Remote()..branchVersion = '1.0.0';
    final api = _SkinApi(await _openStorage(root));

    await http.runWithClient(() async {
      final install = await api.post(
        '/api/v1/webui/skins/install/github-release',
        {'repo': _releaseRepository},
      );
      expect(install.statusCode, 200, reason: '${install.body}');
      final branch = await api.post(
        '/api/v1/webui/skins/install/github-branch',
        {'repo': 'acme/branch-skin', 'branch': 'dist'},
      );
      expect(branch.statusCode, 200, reason: '${branch.body}');
    }, () => remote.client);

    final branchBytes = _snapshot(Directory('${root.path}/branch-skin'));
    final releaseBytes = _snapshot(Directory('${root.path}/release-skin'));

    remote
      ..branchEtag = 'branch-etag-2'
      ..branchVersion = '2.0.0'
      ..branchDownloadStatus = 503
      ..releaseTag = 'v2.0.0'
      ..releaseVersion = '2.0.0'
      ..releaseAssetStatus = 500;

    await http.runWithClient(() async {
      final update = await api.updateSkins();
      expect(update.statusCode, 200, reason: '${update.body}');
      final branchResult = _resultFor(update.body, 'branch-skin');
      expect(branchResult['status'], 'failed');
      expect(branchResult['error'], isA<String>());
      final releaseResult = _resultFor(update.body, 'release-skin');
      expect(releaseResult['status'], 'failed');
      expect(releaseResult['error'], isA<String>());
    }, () => remote.client);

    final idsAfterFailedDownloads = await _withoutNetwork(
      () async => (await api.listSkins())
          .map((skin) => (skin as Map<String, dynamic>)['id'])
          .toList(),
    );

    remote
      ..branchEtag = 'branch-etag-3'
      ..branchDownloadStatus = 200
      ..branchDownloadIsZip = false;

    await http.runWithClient(() async {
      final update = await api.updateSkins();
      final branchResult = _resultFor(update.body, 'branch-skin');
      expect(branchResult['status'], 'failed');
      expect(branchResult['error'], isA<String>());
    }, () => remote.client);

    expect(_snapshot(Directory('${root.path}/branch-skin')), branchBytes);
    expect(_snapshot(Directory('${root.path}/release-skin')), releaseBytes);

    await _withoutNetwork(() async {
      expect(
        (await api.listSkins())
            .map((skin) => (skin as Map<String, dynamic>)['id'])
            .toList(),
        idsAfterFailedDownloads,
        reason: 'a rejected archive must not add an installed skin',
      );
      final branch = await api.installedSkin('branch-skin');
      expect(branch['version'], '1.0.0');
      final branchMetadata = branch['reaMetadata'] as Map<String, dynamic>;
      expect(branchMetadata['etag'], 'branch-etag-1');
      expect(
        branchMetadata['sourceUrl'],
        'github_branch:acme/branch-skin@dist',
      );

      final release = await api.installedSkin('release-skin');
      expect(release['version'], '1.0.0');
      expect(
        (release['reaMetadata'] as Map<String, dynamic>)['sourceUrl'],
        'github_release:acme/release-skin@v1.0.0',
      );
    });
  });

  test(
    'a mixed batch keeps the successful versions and reports every item',
    () async {
      final remote = _Remote();
      final api = _SkinApi(await _openStorage(root));

      await http.runWithClient(() async {
        final release = await api.post(
          '/api/v1/webui/skins/install/github-release',
          {'repo': _releaseRepository},
        );
        expect(release.statusCode, 200, reason: '${release.body}');
        final branch = await api.post(
          '/api/v1/webui/skins/install/github-branch',
          {'repo': 'acme/branch-skin', 'branch': 'dist'},
        );
        expect(branch.statusCode, 200, reason: '${branch.body}');
      }, () => remote.client);

      remote
        ..releaseTag = 'v1.1.0'
        ..releaseVersion = '1.1.0'
        ..branchEtag = 'branch-etag-2'
        ..branchVersion = '9.9.9'
        ..branchDownloadStatus = 503;

      await http.runWithClient(() async {
        final update = await api.updateSkins();
        expect(update.statusCode, 200, reason: '${update.body}');
        final configured = _resultFor(update.body, _configuredRepository);
        expect(configured['status'], 'updated');
        expect(configured, isNot(contains('error')));
        expect(_resultFor(update.body, 'release-skin')['status'], 'updated');
        final branch = _resultFor(update.body, 'branch-skin');
        expect(branch['status'], 'failed');
        expect(branch['error'], isA<String>());
        expect(update.body['results'], hasLength(3));
      }, () => remote.client);

      await _withoutNetwork(() async {
        final listed = await api.listSkins();
        expect(_uniqueSkin(listed, 'configured-skin')['version'], '1.0.0');
        expect(_uniqueSkin(listed, 'release-skin')['version'], '1.1.0');
        expect(_uniqueSkin(listed, 'branch-skin')['version'], '0.4.0');
        expect((await api.installedSkin('release-skin'))['version'], '1.1.0');
        expect((await api.installedSkin('branch-skin'))['version'], '0.4.0');
      });
    },
  );

  test('read routes make no network requests and never touch the skin'
      ' directory', () async {
    final remote = _Remote();
    final api = _SkinApi(await _openStorage(root));

    await http.runWithClient(() async {
      final release = await api.post(
        '/api/v1/webui/skins/install/github-release',
        {'repo': _releaseRepository},
      );
      expect(release.statusCode, 200, reason: '${release.body}');
      final branch = await api.post(
        '/api/v1/webui/skins/install/github-branch',
        {'repo': 'acme/branch-skin', 'branch': 'dist'},
      );
      expect(branch.statusCode, 200, reason: '${branch.body}');
    }, () => remote.client);

    final before = _snapshot(root);
    final requestsBefore = remote.requests;

    await _withoutNetwork(() async {
      expect(await api.listSkins(), isNotEmpty);
      expect((await api.installedSkin('release-skin'))['version'], '1.0.0');
      expect((await api.installedSkin('branch-skin'))['version'], '0.4.0');
      expect(await api.statusOf('/api/v1/webui/skins/missing-skin'), 404);
      expect(await api.statusOf('/api/v1/webui/skins/default'), 200);
    });

    expect(_snapshot(root), before);
    expect(remote.requests, requestsBefore);
    expect(_networkAttempts, isEmpty);
    expect(api.storage.updateCheck.value, isNull);
  });

  test('the OpenAPI contract documents installed-only versions and the'
      ' read-only GET routes', () {
    final spec =
        loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;
    final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
    final skin = schemas['WebUISkin'] as YamlMap;
    final properties = skin['properties'] as YamlMap;
    final version = properties['version'] as YamlMap;

    expect(skin['required'], isNot(contains('version')));
    expect(version['nullable'], isTrue);
    final versionDescription = version['description'] as String;
    expect(versionDescription, contains('Installed version'));
    expect(versionDescription, contains('skin-manifest.json'));
    expect(versionDescription, contains('manifest.json'));
    expect(versionDescription, contains('null'));

    final metadata =
        (schemas['WebUIReaMetadata'] as YamlMap)['properties'] as YamlMap;
    expect(metadata.containsKey('lastChecked'), isTrue);
    expect(metadata.containsKey('availableVersion'), isFalse);
    expect(metadata.containsKey('lastError'), isFalse);
    expect(
      (metadata['lastChecked'] as YamlMap)['description'] as String,
      contains('does not mean the installed version is current'),
    );

    final paths = spec['paths'] as YamlMap;
    final listDescription =
        ((paths['/api/v1/webui/skins'] as YamlMap)['get']
                as YamlMap)['description']
            as String;
    expect(listDescription, contains('installed'));
    expect(listDescription, contains('never contacts GitHub'));
    expect(listDescription, contains('POST /api/v1/webui/skins/update'));

    final skinDescription =
        ((paths['/api/v1/webui/skins/{id}'] as YamlMap)['get']
                as YamlMap)['description']
            as String;
    expect(skinDescription, contains('installed'));
    expect(skinDescription, contains('never contacts GitHub'));

    final update =
        (paths['/api/v1/webui/skins/update'] as YamlMap)['post'] as YamlMap;
    final updateDescription = update['description'] as String;
    expect(updateDescription, contains('only skin API operation'));
    expect(updateDescription, contains('configured sources'));
    expect(updateDescription, contains('install/github-release'));
    expect(updateDescription, contains('install/github-branch'));
    expect(updateDescription, contains('install/url'));
    expect(
      updateDescription,
      contains('installs one explicitly requested source'),
      reason: 'the exclusivity claim must exclude the single-source installs',
    );
    final results =
        (((update['responses'] as YamlMap)['200'] as YamlMap)['content']
                as YamlMap)['application/json']
            as YamlMap;
    final status =
        ((((results['schema'] as YamlMap)['properties'] as YamlMap)['results']
                    as YamlMap)['items']
                as YamlMap)['properties']
            as YamlMap;
    expect((status['status'] as YamlMap)['enum'], [
      'updated',
      'alreadyCurrent',
      'failed',
    ]);
  });
}
