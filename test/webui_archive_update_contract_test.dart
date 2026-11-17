import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'helpers/mock_settings_service.dart';

const _sourcesAsset = 'skin_sources.json';
const _bundledManifestAsset = 'assets/bundled_skins/manifest.json';

const _releaseRepository = 'acme/release-skin';
const _releaseApiUrl =
    'https://api.github.com/repos/acme/release-skin/releases/latest';
const _branchUrl =
    'https://github.com/acme/branch-skin/archive/refs/heads/dist.zip';
const _alphaUrl = 'https://example.test/alpha.zip';

const _releaseId = 'release-skin';
const _branchId = 'branch-skin';
const _alphaId = 'alpha-skin';
const _stagingDirName = '.webui-install-staging';

Uint8List _encoded(Iterable<ArchiveFile> files) {
  final archive = Archive();
  for (final file in files) {
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _zip({
  required String root,
  required String id,
  String? name,
  String? version,
  String manifestName = 'skin-manifest.json',
  bool includeManifest = true,
  String indexHtml = '<html>skin</html>',
}) {
  final files = <ArchiveFile>[];
  if (includeManifest) {
    files.add(
      ArchiveFile.string(
        '$root/$manifestName',
        jsonEncode({'id': id, 'name': name ?? id, 'version': ?version}),
      ),
    );
  }
  files.add(ArchiveFile.string('$root/index.html', indexHtml));
  return _encoded(files);
}

Uint8List _truncated(Uint8List bytes) =>
    Uint8List.sublistView(bytes, 0, bytes.length - 10);

Uint8List _emptyFilenameZip(String id) {
  final bytes = _encoded([
    ArchiveFile.string(
      '$id/skin-manifest.json',
      jsonEncode({'id': id, 'name': id, 'version': '2.0.0'}),
    ),
    ArchiveFile.string('$id/index.html', '<html>partial</html>'),
    ArchiveFile.string('', 'junk'),
  ]);
  expect(
    ZipDecoder().decodeBytes(bytes).files.map((file) => file.name),
    contains(''),
    reason: 'the encoded fixture must retain the empty-path entry',
  );
  return bytes;
}

Uint8List _fileDirectoryConflictZip(String id) {
  final bytes = _encoded([
    ArchiveFile.string(
      '$id/skin-manifest.json',
      jsonEncode({'id': id, 'name': id, 'version': '2.0.0'}),
    ),
    ArchiveFile.string('$id/index.html', '<html>conflict</html>'),
    ArchiveFile.string('$id/index.html/child.txt', 'conflict'),
  ]);
  expect(
    ZipDecoder().decodeBytes(bytes).files.map((file) => file.name),
    contains('$id/index.html/child.txt'),
    reason: 'the encoded fixture must retain the conflicting entry',
  );
  return bytes;
}

Uint8List _archiveWithManifestField(
  String root,
  String field,
  Object? value, {
  required String manifestName,
}) {
  final manifest = <String, dynamic>{
    'id': root,
    'name': 'Skin',
    'version': '2.0.0',
  }..[field] = value;
  return _encoded([
    ArchiveFile.string('$root/index.html', '<html>updated</html>'),
    ArchiveFile.string('$root/$manifestName', jsonEncode(manifest)),
  ]);
}

Uint8List _damaged(Uint8List bytes, String marker) {
  final pattern = utf8.encode(marker);
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    var hit = true;
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        hit = false;
        break;
      }
    }
    if (hit) {
      final corrupt = Uint8List.fromList(bytes);
      corrupt[i] = pattern[0] == 0x41 ? 0x42 : 0x41;
      return corrupt;
    }
  }
  fail('marker "$marker" not found in the encoded archive');
}

Map<String, dynamic> _releaseJson(String tag) => {
  'tag_name': tag,
  'name': 'Release $tag',
  'published_at': '2026-01-01T00:00:00Z',
  'assets': [
    {
      'name': 'release-skin.zip',
      'browser_download_url':
          'https://github.com/$_releaseRepository/releases/download/'
          '$tag/release-skin.zip',
      'size': 1234,
    },
  ],
};

class _Remote {
  _Remote() {
    releaseBytes = _zip(
      root: _releaseId,
      id: _releaseId,
      version: '1.0.0',
      indexHtml: '<html>release 1.0.0</html>',
    );
    branchBytes = _zip(
      root: _branchId,
      id: _branchId,
      version: '0.4.0',
      manifestName: 'manifest.json',
      indexHtml: '<html>branch 0.4.0</html>',
    );
    urlBytes[_alphaUrl] = _zip(
      root: 'dist',
      id: _alphaId,
      version: '1.0.0',
      indexHtml: '<html>alpha 1.0.0</html>',
    );
  }

  String releaseTag = 'v1.0.0';
  late Uint8List releaseBytes;
  int releaseStatus = 200;

  String branchEtag = 'branch-etag-1';
  late Uint8List branchBytes;
  int branchStatus = 200;

  final Map<String, Uint8List> urlBytes = {};
  final Map<String, String> urlEtags = {};

  int requests = 0;

  MockClient get client => MockClient(_handle);

  String get _releaseDownloadUrl =>
      'https://github.com/$_releaseRepository/releases/download/'
      '$releaseTag/release-skin.zip';

  Future<http.Response> _handle(http.Request request) async {
    requests++;
    final url = request.url.toString();

    if (url == _releaseApiUrl) {
      return http.Response.bytes(
        utf8.encode(jsonEncode(_releaseJson(releaseTag))),
        200,
      );
    }
    if (url == _releaseDownloadUrl) {
      if (releaseStatus != 200) {
        return http.Response('unavailable', releaseStatus);
      }
      return http.Response.bytes(releaseBytes, 200);
    }
    if (url == _branchUrl) {
      if (request.method == 'HEAD') {
        return http.Response('', 200, headers: {'etag': branchEtag});
      }
      if (branchStatus != 200) {
        return http.Response('unavailable', branchStatus);
      }
      return http.Response.bytes(branchBytes, 200);
    }
    final asset = urlBytes[url];
    if (asset != null) {
      final etag = urlEtags[url] ?? 'url-etag-1';
      if (request.method == 'HEAD') {
        return http.Response('', 200, headers: {'etag': etag});
      }
      return http.Response.bytes(asset, 200, headers: {'etag': etag});
    }
    return http.Response('not found: $url', 404);
  }
}

class _FailingCopyStorage extends WebUIStorage {
  _FailingCopyStorage(super.settingsController, {required super.webUIDir});

  bool armed = false;

  @override
  Future<void> copySkinFiles(Directory source, Directory destination) async {
    if (armed) {
      throw const FileSystemException('simulated copy failure');
    }
    await super.copySkinFiles(source, destination);
  }
}

class _FailingMoveStorage extends WebUIStorage {
  _FailingMoveStorage(super.settingsController, {required super.webUIDir});

  bool armed = false;

  @override
  Future<void> moveSkinDirectory(
    Directory source,
    Directory destination,
  ) async {
    if (armed && p.basename(source.path).startsWith('candidate_')) {
      throw const FileSystemException('simulated rename failure');
    }
    await super.moveSkinDirectory(source, destination);
  }
}

class _FailingMoveAsideStorage extends WebUIStorage {
  _FailingMoveAsideStorage(
    super.settingsController, {
    required super.webUIDir,
    required this.installedId,
  });

  final String installedId;
  bool armed = false;

  @override
  Future<void> moveSkinDirectory(
    Directory source,
    Directory destination,
  ) async {
    if (armed && p.basename(source.path) == installedId) {
      throw const FileSystemException('simulated move-aside failure');
    }
    await super.moveSkinDirectory(source, destination);
  }
}

class _FailingRestoreStorage extends WebUIStorage {
  _FailingRestoreStorage(super.settingsController, {required super.webUIDir});

  bool armed = false;

  final List<String> moves = [];

  List<String> get candidateMoves =>
      moves.where((move) => move.startsWith('candidate_')).toList();

  List<String> get previousMoves =>
      moves.where((move) => move.startsWith('previous_')).toList();

  @override
  Future<void> moveSkinDirectory(
    Directory source,
    Directory destination,
  ) async {
    final name = p.basename(source.path);
    moves.add(name);
    if (armed &&
        (name.startsWith('candidate_') || name.startsWith('previous_'))) {
      throw const FileSystemException('simulated replacement failure');
    }
    await super.moveSkinDirectory(source, destination);
  }
}

Handler _buildHandler(WebUIStorage storage) {
  final webUIHandler = WebUIHandler(storage: storage, service: WebUIService());
  final app = Router().plus;
  webUIHandler.addRoutes(app);
  return app.call;
}

class _Api {
  _Api(this.storage) : handler = _buildHandler(storage);

  final WebUIStorage storage;
  final Handler handler;

  Future<List<Map<String, dynamic>>> list() async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/webui/skins')),
    );
    final text = await response.readAsString();
    expect(response.statusCode, 200, reason: text);
    return (jsonDecode(text) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> skin(String id) async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/api/v1/webui/skins/$id')),
    );
    final text = await response.readAsString();
    expect(response.statusCode, 200, reason: text);
    return jsonDecode(text) as Map<String, dynamic>;
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

  Future<({int statusCode, Map<String, dynamic> body})> update() =>
      post('/api/v1/webui/skins/update');

  Future<int> statusOf(String path) async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost$path')),
    );
    await response.readAsString();
    return response.statusCode;
  }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late Directory tempRoot;
  late Directory webUIDir;

  setUp(() {
    tmpRoot = Directory.systemTemp.createTempSync('webui_archive_update');
    tempRoot = Directory('${tmpRoot.path}/tmp')..createSync();
    webUIDir = Directory('${tmpRoot.path}/web-ui');
    rootBundle.evict(_sourcesAsset);
    rootBundle.evict(_bundledManifestAsset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final key = const StringCodec().decodeMessage(message);
          if (key != _sourcesAsset && key != _bundledManifestAsset) return null;
          return ByteData.sublistView(
            Uint8List.fromList(utf8.encode(jsonEncode(const <Object>[]))),
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
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  Future<SettingsController> newSettings() async {
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
    return settings;
  }

  Future<WebUIStorage> openStorage([WebUIStorage? storage]) async {
    final instance =
        storage ?? WebUIStorage(await newSettings(), webUIDir: webUIDir);
    await instance.initialize(downloadRemote: false);
    return instance;
  }

  Future<_Api> openApi([WebUIStorage? storage]) async =>
      _Api(await openStorage(storage));

  Future<_Api> reloadedApi() async => _Api(await openStorage());

  Future<void> installRelease(_Api api) async {
    final result = await api.post(
      '/api/v1/webui/skins/install/github-release',
      {'repo': _releaseRepository},
    );
    expect(result.statusCode, 200, reason: '${result.body}');
  }

  Future<void> installBranch(_Api api) async {
    final result = await api.post('/api/v1/webui/skins/install/github-branch', {
      'repo': 'acme/branch-skin',
      'branch': 'dist',
    });
    expect(result.statusCode, 200, reason: '${result.body}');
  }

  Future<void> installAlpha(_Api api) async {
    final result = await api.post('/api/v1/webui/skins/install/url', {
      'url': _alphaUrl,
    });
    expect(result.statusCode, 200, reason: '${result.body}');
  }

  Directory skinDir(String id) => Directory('${webUIDir.path}/$id');

  Map<String, String> snapshot(Directory directory) {
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

  List<String> directoryNames() => webUIDir
      .listSync()
      .whereType<Directory>()
      .map((dir) => p.basename(dir.path))
      .toList();

  List<String> extractionDirectories() => tempRoot.listSync().isEmpty
      ? const []
      : tempRoot
            .listSync()
            .whereType<Directory>()
            .map((dir) => p.basename(dir.path))
            .where((name) => name.startsWith('webui_extract'))
            .toList();

  Future<List<String>> listedIds(_Api api) async =>
      (await api.list()).map((skin) => skin['id'] as String).toList();

  Future<Map<String, dynamic>> metadataOf(_Api api, String id) async =>
      (await api.skin(id))['reaMetadata'] as Map<String, dynamic>;

  Future<String?> versionViaBothRoutes(_Api api, String id) async {
    final item = (await api.skin(id))['version'] as String?;
    final listed = (await api.list()).firstWhere(
      (skin) => skin['id'] == id,
      orElse: () => fail('"$id" is missing from the skin list'),
    );
    expect(listed['version'], item, reason: 'list and item routes disagree');
    return item;
  }

  Future<void> expectRejectedUpdateKeepsInstall(
    _Api api, {
    required String targetId,
    required Map<String, String> filesBefore,
    required Map<String, dynamic> metadataBefore,
    required String? expectedVersion,
    required List<String> idsBefore,
  }) async {
    expect(snapshot(skinDir(targetId)), filesBefore);
    expect(await metadataOf(api, targetId), metadataBefore);
    expect(await versionViaBothRoutes(api, targetId), expectedVersion);

    final idsAfter = await listedIds(api);
    expect(idsAfter, unorderedEquals(idsBefore));
    expect(idsAfter, isNot(contains(_stagingDirName)));
    expect(directoryNames().toSet(), idsBefore.toSet());
    expect(directoryNames(), isNot(contains(_stagingDirName)));
    expect(extractionDirectories(), isEmpty);

    final reloaded = await reloadedApi();
    expect(await listedIds(reloaded), unorderedEquals(idsBefore));
    expect(snapshot(skinDir(targetId)), filesBefore);
    final reloadedListed = (await reloaded.list()).firstWhere(
      (skin) => skin['id'] == targetId,
      orElse: () => fail('"$targetId" is missing from the reloaded skin list'),
    );
    expect(reloadedListed['version'], expectedVersion);
    expect(reloadedListed['reaMetadata'], metadataBefore);
    expect(await versionViaBothRoutes(reloaded, targetId), expectedVersion);
    expect(await metadataOf(reloaded, targetId), metadataBefore);
  }

  Future<void> expectRejectedUpdate({
    required _Remote remote,
    required String path,
    required Uint8List Function(String id) payload,
    WebUIStorage? storage,
    void Function()? arm,
    String? errorContains,
  }) async {
    final api = await openApi(storage);
    await http.runWithClient(() async {
      if (path == 'release') {
        await installRelease(api);
      } else {
        await installBranch(api);
      }
      await installAlpha(api);
    }, () => remote.client);

    final targetId = path == 'release' ? _releaseId : _branchId;
    final filesBefore = snapshot(skinDir(targetId));
    final alphaBefore = snapshot(skinDir(_alphaId));
    final metadataBefore = await metadataOf(api, targetId);
    final versionBefore = await versionViaBothRoutes(api, targetId);
    final idsBefore = await listedIds(api);

    if (path == 'release') {
      remote.releaseTag = 'v2.0.0';
      remote.releaseBytes = payload(_releaseId);
    } else {
      remote.branchEtag = 'branch-etag-2';
      remote.branchBytes = payload(_branchId);
    }
    arm?.call();

    await http.runWithClient(() async {
      final update = await api.update();
      expect(update.statusCode, 200, reason: '${update.body}');
      final result = _resultFor(update.body, targetId);
      expect(result['status'], 'failed', reason: '${update.body}');
      expect(result['error'], isA<String>());
      if (errorContains != null) {
        expect(
          result['error'],
          contains(errorContains),
          reason: '${update.body}',
        );
      }

      await expectRejectedUpdateKeepsInstall(
        api,
        targetId: targetId,
        filesBefore: filesBefore,
        metadataBefore: metadataBefore,
        expectedVersion: versionBefore,
        idsBefore: idsBefore,
      );
      expect(snapshot(skinDir(_alphaId)), alphaBefore);
      expect(await versionViaBothRoutes(api, _alphaId), '1.0.0');
    }, () => remote.client);
  }

  final invalidPayloads = <String, Uint8List Function(String id)>{
    'an HTTP 200 body that is not a ZIP': (id) =>
        Uint8List.fromList(utf8.encode('this is not a zip archive at all')),
    'a valid ZIP with no entries': (id) => _encoded(const []),
    'a directory-only ZIP': (id) => _encoded([
      ArchiveFile.directory('$id/'),
      ArchiveFile.directory('$id/assets/'),
    ]),
    'a README-only ZIP': (id) =>
        _encoded([ArchiveFile.string('$id/README.md', '# readme')]),
    'an archive without index.html at its root': (id) => _encoded([
      ArchiveFile.string(
        '$id/skin-manifest.json',
        jsonEncode({'id': id, 'name': id, 'version': '2.0.0'}),
      ),
    ]),
    'a truncated archive': (id) =>
        _truncated(_zip(root: id, id: id, version: '2.0.0')),
    'an archive with a damaged entry': (id) => _damaged(
      _encoded([
        ArchiveFile.noCompress(
          '$id/index.html',
          16,
          utf8.encode('SKINBODY_SKINBODY'),
        ),
        ArchiveFile.string(
          '$id/skin-manifest.json',
          jsonEncode({'id': id, 'name': id, 'version': '2.0.0'}),
        ),
      ]),
      'SKINBODY',
    ),
    'a valid root skin plus an empty-filename entry': (id) =>
        _emptyFilenameZip(id),
    'a ZIP whose file entry conflicts with a directory': (id) =>
        _fileDirectoryConflictZip(id),
  };

  for (final path in const ['release', 'branch']) {
    group('$path update rejects unusable payloads without touching installed '
        'skins', () {
      for (final entry in invalidPayloads.entries) {
        test(entry.key, () async {
          await expectRejectedUpdate(
            remote: _Remote(),
            path: path,
            payload: entry.value,
          );
        });
      }

      test('a staging copy failure', () async {
        final storage = _FailingCopyStorage(
          await newSettings(),
          webUIDir: webUIDir,
        );
        await expectRejectedUpdate(
          remote: _Remote(),
          path: path,
          payload: (id) => _zip(root: id, id: id, version: '2.0.0'),
          storage: storage,
          arm: () => storage.armed = true,
        );
      });

      test('a staged rename failure', () async {
        final storage = _FailingMoveStorage(
          await newSettings(),
          webUIDir: webUIDir,
        );
        await expectRejectedUpdate(
          remote: _Remote(),
          path: path,
          payload: (id) => _zip(root: id, id: id, version: '2.0.0'),
          storage: storage,
          arm: () => storage.armed = true,
        );
      });

      test('a move-aside failure keeps the previous skin', () async {
        final targetId = path == 'release' ? _releaseId : _branchId;
        final storage = _FailingMoveAsideStorage(
          await newSettings(),
          webUIDir: webUIDir,
          installedId: targetId,
        );
        await expectRejectedUpdate(
          remote: _Remote(),
          path: path,
          payload: (id) => _zip(root: id, id: id, version: '2.0.0'),
          storage: storage,
          arm: () => storage.armed = true,
        );
      });

      for (final field in const ['id', 'name', 'description', 'version']) {
        for (final manifestName in const [
          'skin-manifest.json',
          'manifest.json',
        ]) {
          test(
            'a $manifestName whose $field is not a string is rejected',
            () async {
              await expectRejectedUpdate(
                remote: _Remote(),
                path: path,
                payload: (id) => _archiveWithManifestField(
                  id,
                  field,
                  2,
                  manifestName: manifestName,
                ),
                errorContains: 'invalid "$field" value',
              );
            },
          );
        }
      }
    });
  }

  for (final path in const ['release', 'branch']) {
    group('$path update accepts usable skin packages', () {
      for (final manifestName in const [
        'skin-manifest.json',
        'manifest.json',
      ]) {
        test(
          'index.html plus $manifestName replaces the installed skin',
          () async {
            final remote = _Remote();
            final api = await openApi();
            await http.runWithClient(() async {
              if (path == 'release') {
                await installRelease(api);
              } else {
                await installBranch(api);
              }
            }, () => remote.client);

            final id = path == 'release' ? _releaseId : _branchId;
            final version = path == 'release' ? '1.1.0' : '0.5.0';
            final payload = _zip(
              root: id,
              id: id,
              version: version,
              manifestName: manifestName,
              indexHtml: '<html>updated</html>',
            );
            if (path == 'release') {
              remote
                ..releaseTag = 'v1.1.0'
                ..releaseBytes = payload;
            } else {
              remote
                ..branchEtag = 'branch-etag-2'
                ..branchBytes = payload;
            }

            await http.runWithClient(() async {
              final update = await api.update();
              expect(update.statusCode, 200, reason: '${update.body}');
              expect(
                _resultFor(update.body, id)['status'],
                'updated',
                reason: '${update.body}',
              );
              expect((await api.skin(id))['version'], version);
            }, () => remote.client);

            expect(
              File('${webUIDir.path}/$id/index.html').readAsStringSync(),
              '<html>updated</html>',
            );
            expect(await listedIds(api), [id]);
            expect(directoryNames(), [id]);
            final reloaded = await reloadedApi();
            expect((await reloaded.skin(id))['version'], version);
            expect(await listedIds(reloaded), [id]);
          },
        );
      }
    });
  }

  group('update identity binding', () {
    test(
      'a release update cannot redirect to another installed skin',
      () async {
        final remote = _Remote();
        final api = await openApi();
        await http.runWithClient(() async {
          await installRelease(api);
          await installAlpha(api);
        }, () => remote.client);

        final releaseBefore = snapshot(skinDir(_releaseId));
        final alphaBefore = snapshot(skinDir(_alphaId));
        final metadataBefore = await metadataOf(api, _releaseId);
        final versionBefore = await versionViaBothRoutes(api, _releaseId);
        final idsBefore = await listedIds(api);

        remote
          ..releaseTag = 'v2.0.0'
          ..releaseBytes = _zip(
            root: _releaseId,
            id: _alphaId,
            version: '9.9.9',
            indexHtml: '<html>hijack</html>',
          );

        await http.runWithClient(() async {
          final update = await api.update();
          expect(update.statusCode, 200, reason: '${update.body}');
          final result = _resultFor(update.body, _releaseId);
          expect(result['status'], 'failed', reason: '${update.body}');
          expect(result['error'], contains('different skin id'));

          await expectRejectedUpdateKeepsInstall(
            api,
            targetId: _releaseId,
            filesBefore: releaseBefore,
            metadataBefore: metadataBefore,
            expectedVersion: versionBefore,
            idsBefore: idsBefore,
          );
          expect(snapshot(skinDir(_alphaId)), alphaBefore);
          expect(await versionViaBothRoutes(api, _alphaId), '1.0.0');
        }, () => remote.client);
      },
    );

    test('a branch update cannot redirect to another installed skin', () async {
      final remote = _Remote();
      final api = await openApi();
      await http.runWithClient(() async {
        await installBranch(api);
        await installAlpha(api);
      }, () => remote.client);

      final branchBefore = snapshot(skinDir(_branchId));
      final alphaBefore = snapshot(skinDir(_alphaId));
      final metadataBefore = await metadataOf(api, _branchId);
      final versionBefore = await versionViaBothRoutes(api, _branchId);
      final idsBefore = await listedIds(api);

      remote
        ..branchEtag = 'branch-etag-2'
        ..branchBytes = _zip(
          root: _branchId,
          id: _alphaId,
          version: '9.9.9',
          manifestName: 'manifest.json',
        );

      await http.runWithClient(() async {
        final update = await api.update();
        expect(update.statusCode, 200, reason: '${update.body}');
        final result = _resultFor(update.body, _branchId);
        expect(result['status'], 'failed', reason: '${update.body}');
        expect(result['error'], contains('different skin id'));

        await expectRejectedUpdateKeepsInstall(
          api,
          targetId: _branchId,
          filesBefore: branchBefore,
          metadataBefore: metadataBefore,
          expectedVersion: versionBefore,
          idsBefore: idsBefore,
        );
        expect(snapshot(skinDir(_alphaId)), alphaBefore);
      }, () => remote.client);
    });

    test('a URL update cannot redirect to another installed skin', () async {
      final remote = _Remote();
      final api = await openApi();
      await http.runWithClient(() async {
        await installRelease(api);
        await installAlpha(api);
      }, () => remote.client);

      final alphaBefore = snapshot(skinDir(_alphaId));
      final releaseBefore = snapshot(skinDir(_releaseId));
      final metadataBefore = await metadataOf(api, _alphaId);
      final versionBefore = await versionViaBothRoutes(api, _alphaId);
      final idsBefore = await listedIds(api);

      remote.urlBytes[_alphaUrl] = _zip(
        root: 'dist',
        id: _releaseId,
        version: '9.9.9',
      );
      remote.urlEtags[_alphaUrl] = 'url-etag-2';

      await http.runWithClient(() async {
        final update = await api.update();
        expect(update.statusCode, 200, reason: '${update.body}');
        final result = _resultFor(update.body, _alphaId);
        expect(result['status'], 'failed', reason: '${update.body}');
        expect(result['error'], contains('different skin id'));

        await expectRejectedUpdateKeepsInstall(
          api,
          targetId: _alphaId,
          filesBefore: alphaBefore,
          metadataBefore: metadataBefore,
          expectedVersion: versionBefore,
          idsBefore: idsBefore,
        );
        expect(snapshot(skinDir(_releaseId)), releaseBefore);
      }, () => remote.client);
    });

    test('a release update keeps the installed identity when the tag changes'
        ' and the archive is manifestless', () async {
      final remote = _Remote();
      final api = await openApi();
      await http.runWithClient(() async {
        await installRelease(api);
        await installAlpha(api);
      }, () => remote.client);

      remote
        ..releaseTag = 'v1.1.0'
        ..releaseBytes = _zip(
          root: r'release-skin-1.1.0',
          id: _releaseId,
          includeManifest: false,
          indexHtml: '<html>release 1.1.0</html>',
        );

      await http.runWithClient(() async {
        final update = await api.update();
        expect(update.statusCode, 200, reason: '${update.body}');
        expect(_resultFor(update.body, _releaseId)['status'], 'updated');
      }, () => remote.client);

      expect(
        File('${webUIDir.path}/$_releaseId/index.html').readAsStringSync(),
        '<html>release 1.1.0</html>',
      );
      expect(await listedIds(api), unorderedEquals([_releaseId, _alphaId]));
      expect(directoryNames().toSet(), {_releaseId, _alphaId});

      final reloaded = await reloadedApi();
      expect(
        await listedIds(reloaded),
        unorderedEquals([_releaseId, _alphaId]),
      );
      expect(
        File('${webUIDir.path}/$_releaseId/index.html').readAsStringSync(),
        '<html>release 1.1.0</html>',
      );
    });

    test('a branch update keeps the installed identity when the archive is'
        ' manifestless', () async {
      final remote = _Remote();
      final api = await openApi();
      await http.runWithClient(() async {
        await installBranch(api);
        await installAlpha(api);
      }, () => remote.client);

      remote
        ..branchEtag = 'branch-etag-2'
        ..branchBytes = _zip(
          root: 'branch-skin-0.5.0',
          id: _branchId,
          includeManifest: false,
          indexHtml: '<html>branch 0.5.0</html>',
        );

      await http.runWithClient(() async {
        final update = await api.update();
        expect(update.statusCode, 200, reason: '${update.body}');
        expect(_resultFor(update.body, _branchId)['status'], 'updated');
      }, () => remote.client);

      expect(
        File('${webUIDir.path}/$_branchId/index.html').readAsStringSync(),
        '<html>branch 0.5.0</html>',
      );
      expect(await listedIds(api), unorderedEquals([_branchId, _alphaId]));
      expect(directoryNames().toSet(), {_branchId, _alphaId});
    });

    test(
      'a fresh install still adopts the skin id declared by its manifest',
      () async {
        final remote = _Remote();
        final api = await openApi();
        remote.urlBytes[_alphaUrl] = _zip(
          root: 'dist',
          id: 'fresh-from-manifest',
          version: '3.0.0',
        );

        await http.runWithClient(() => installAlpha(api), () => remote.client);

        expect(await listedIds(api), ['fresh-from-manifest']);
        expect((await api.skin('fresh-from-manifest'))['version'], '3.0.0');
        expect(directoryNames(), ['fresh-from-manifest']);
        final reloaded = await reloadedApi();
        expect(await listedIds(reloaded), ['fresh-from-manifest']);
      },
    );
  });

  group('reserved staging container id', () {
    test('an archive declaring the staging container as its skin id is'
        ' rejected by a fresh install', () async {
      final remote = _Remote();
      final api = await openApi();
      remote.urlBytes[_alphaUrl] = _zip(
        root: _stagingDirName,
        id: _stagingDirName,
        version: '1.0.0',
      );

      final response = await http.runWithClient(
        () => api.post('/api/v1/webui/skins/install/url', {'url': _alphaUrl}),
        () => remote.client,
      );

      expect(response.statusCode, greaterThanOrEqualTo(400));
      expect('${response.body['error']}', contains('reserved skin id'));
      expect(await listedIds(api), isEmpty);
      expect(directoryNames(), isNot(contains(_stagingDirName)));
      final reloaded = await reloadedApi();
      expect(await listedIds(reloaded), isEmpty);
    });

    test(
      'an update declaring the staging container as its skin id is rejected',
      () async {
        final remote = _Remote();
        final api = await openApi();
        await http.runWithClient(() => installAlpha(api), () => remote.client);
        final alphaBefore = snapshot(skinDir(_alphaId));
        final metadataBefore = await metadataOf(api, _alphaId);

        remote.urlBytes[_alphaUrl] = _zip(
          root: _stagingDirName,
          id: _stagingDirName,
          version: '2.0.0',
        );
        remote.urlEtags[_alphaUrl] = 'url-etag-2';

        await http.runWithClient(() async {
          final update = await api.update();
          expect(update.statusCode, 200, reason: '${update.body}');
          final result = _resultFor(update.body, _alphaId);
          expect(result['status'], 'failed', reason: '${update.body}');
          expect('${result['error']}', contains('reserved skin id'));
        }, () => remote.client);

        expect(snapshot(skinDir(_alphaId)), alphaBefore);
        expect(await metadataOf(api, _alphaId), metadataBefore);
        expect(await listedIds(api), [_alphaId]);
        expect(directoryNames(), [_alphaId]);
      },
    );
  });

  group('mixed batch continuation', () {
    test(
      'a failing release update does not stop the branch update after it',
      () async {
        final remote = _Remote();
        final api = await openApi();
        await http.runWithClient(() async {
          await installRelease(api);
          await installBranch(api);
        }, () => remote.client);

        final releaseBefore = snapshot(skinDir(_releaseId));
        final releaseMetadataBefore = await metadataOf(api, _releaseId);
        remote
          ..releaseTag = 'v2.0.0'
          ..releaseBytes = _encoded([
            ArchiveFile.string('$_releaseId/README.md', '# broken'),
          ])
          ..branchEtag = 'branch-etag-2'
          ..branchBytes = _zip(
            root: _branchId,
            id: _branchId,
            version: '0.5.0',
            manifestName: 'manifest.json',
            indexHtml: '<html>branch 0.5.0</html>',
          );

        await http.runWithClient(() async {
          final update = await api.update();
          expect(update.statusCode, 200, reason: '${update.body}');
          expect(
            (update.body['results'] as List).map(
              (result) => (result as Map<String, dynamic>)['item'],
            ),
            [_releaseId, _branchId],
          );
          expect(_resultFor(update.body, _releaseId)['status'], 'failed');
          expect(_resultFor(update.body, _branchId)['status'], 'updated');
        }, () => remote.client);

        expect(snapshot(skinDir(_releaseId)), releaseBefore);
        expect(await metadataOf(api, _releaseId), releaseMetadataBefore);
        expect(await versionViaBothRoutes(api, _branchId), '0.5.0');

        final reloaded = await reloadedApi();
        expect(await versionViaBothRoutes(reloaded, _branchId), '0.5.0');
        expect(snapshot(skinDir(_releaseId)), releaseBefore);
        expect(await metadataOf(reloaded, _releaseId), releaseMetadataBefore);
        expect(
          await listedIds(reloaded),
          unorderedEquals([_releaseId, _branchId]),
        );
      },
    );

    test('a successful release update persists when the later branch update'
        ' fails', () async {
      final remote = _Remote();
      final api = await openApi();
      await http.runWithClient(() async {
        await installRelease(api);
        await installBranch(api);
      }, () => remote.client);

      final idsBefore = await listedIds(api);
      final branchBefore = snapshot(skinDir(_branchId));
      final branchMetadataBefore = await metadataOf(api, _branchId);
      remote
        ..branchEtag = 'branch-etag-2'
        ..branchBytes = _encoded([
          ArchiveFile.string('$_branchId/README.md', '# broken'),
        ])
        ..releaseTag = 'v1.1.0'
        ..releaseBytes = _zip(
          root: _releaseId,
          id: _releaseId,
          version: '1.1.0',
          indexHtml: '<html>release 1.1.0</html>',
        );

      await http.runWithClient(() async {
        final update = await api.update();
        expect(update.statusCode, 200, reason: '${update.body}');
        expect(
          (update.body['results'] as List).map(
            (result) => (result as Map<String, dynamic>)['item'],
          ),
          [_releaseId, _branchId],
        );
        expect(_resultFor(update.body, _releaseId)['status'], 'updated');
        final failed = _resultFor(update.body, _branchId);
        expect(failed['status'], 'failed');
        expect(failed['error'], isA<String>());
      }, () => remote.client);

      expect(await versionViaBothRoutes(api, _releaseId), '1.1.0');
      expect(snapshot(skinDir(_branchId)), branchBefore);
      expect(await metadataOf(api, _branchId), branchMetadataBefore);

      final reloaded = await reloadedApi();
      expect(await versionViaBothRoutes(reloaded, _releaseId), '1.1.0');
      expect(snapshot(skinDir(_branchId)), branchBefore);
      expect(await metadataOf(reloaded, _branchId), branchMetadataBefore);
      expect(await listedIds(reloaded), unorderedEquals(idsBefore));
      expect(directoryNames().toSet(), idsBefore.toSet());
    });
  });

  group('failed replacement and failed restore', () {
    test(
      'the previous skin is retained under staging and never reported',
      () async {
        final remote = _Remote();
        final storage = _FailingRestoreStorage(
          await newSettings(),
          webUIDir: webUIDir,
        );
        final api = _Api(await openStorage(storage));
        final records = <LogRecord>[];
        final subscription = Logger.root.onRecord.listen((record) {
          if (record.loggerName == 'WebUIStorage') records.add(record);
        });
        addTearDown(subscription.cancel);

        await http.runWithClient(
          () => installRelease(api),
          () => remote.client,
        );
        final releaseBefore = snapshot(skinDir(_releaseId));

        remote
          ..releaseTag = 'v2.0.0'
          ..releaseBytes = _zip(
            root: _releaseId,
            id: _releaseId,
            version: '2.0.0',
            indexHtml: '<html>release 2.0.0</html>',
          );
        storage.moves.clear();
        storage.armed = true;

        await http.runWithClient(() async {
          final update = await api.update();
          expect(update.statusCode, 200, reason: '${update.body}');
          final result = _resultFor(update.body, _releaseId);
          expect(result['status'], 'failed', reason: '${update.body}');
          expect(result['error'], isA<String>());
        }, () => remote.client);

        expect(storage.candidateMoves, hasLength(1));
        expect(storage.previousMoves, hasLength(1));
        expect(storage.moves, [
          _releaseId,
          storage.candidateMoves.single,
          storage.previousMoves.single,
        ]);

        expect(skinDir(_releaseId).existsSync(), isFalse);
        final stagingRoot = Directory('${webUIDir.path}/$_stagingDirName');
        final stagingEntries = stagingRoot
            .listSync()
            .map((entity) => p.basename(entity.path))
            .toList();
        expect(stagingEntries, [storage.previousMoves.single]);
        expect(
          stagingEntries.where((name) => name.startsWith('candidate_')),
          isEmpty,
        );
        final backups = stagingRoot
            .listSync()
            .whereType<Directory>()
            .where((dir) => p.basename(dir.path).startsWith('previous_'))
            .toList();
        expect(backups, hasLength(1));
        expect(p.basename(backups.single.path), storage.previousMoves.single);
        expect(snapshot(backups.single), releaseBefore);

        final restoreFailures = records
            .where(
              (record) =>
                  record.level == Level.SEVERE &&
                  record.message.contains(
                    'Failed to restore the previous skin',
                  ),
            )
            .toList();
        expect(
          restoreFailures,
          hasLength(1),
          reason: records.map((r) => '${r.level} ${r.message}').join('\n'),
        );
        expect(restoreFailures.single.message, contains(backups.single.path));
        expect(restoreFailures.single.message, contains('it is preserved at'));

        expect(await listedIds(api), isEmpty);
        expect(await api.statusOf('/api/v1/webui/skins/$_releaseId'), 404);

        final reloaded = await reloadedApi();
        expect(await listedIds(reloaded), isEmpty);
        expect(await reloaded.statusOf('/api/v1/webui/skins/$_releaseId'), 404);
        expect(snapshot(backups.single), releaseBefore);
      },
    );
  });
}
