import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as paths;
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/util/remote_error.dart';
import 'package:reaprime/src/util/remote_update_report.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import 'helpers/mock_settings_service.dart';

const _alphaUrl = 'https://example.test/alpha.zip';
const _betaUrl = 'https://example.test/beta.zip';
const _sourcesAsset = 'skin_sources.json';
const _bundledManifestAsset = 'assets/bundled_skins/manifest.json';

Uint8List _encoded(Iterable<ArchiveFile> files) {
  final archive = Archive();
  for (final file in files) {
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _entryName(String root, String name) =>
    root.isEmpty ? name : '$root/$name';

Map<String, dynamic> _manifest(
  String id, {
  String name = 'Skin',
  String? version,
}) => {'id': id, 'name': name, 'version': ?version};

Uint8List _skinArchive({
  String root = 'passione-dist',
  Map<String, dynamic>? manifest,
  String manifestName = 'skin-manifest.json',
  String indexHtml = '<html>skin</html>',
  bool includeIndex = true,
}) {
  final manifestJson =
      manifest ??
      _manifest(
        root.isEmpty ? 'rooted-skin' : paths.basename(root),
        version: '1.0.0',
      );
  final files = <ArchiveFile>[];
  if (includeIndex) {
    files.add(ArchiveFile.string(_entryName(root, 'index.html'), indexHtml));
  }
  files.add(
    ArchiveFile.string(
      _entryName(root, manifestName),
      jsonEncode(manifestJson),
    ),
  );
  return _encoded(files);
}

Uint8List _flipStoredByte(Uint8List bytes, String marker) {
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

Uint8List _truncated(Uint8List bytes, int dropBytes) =>
    Uint8List.sublistView(bytes, 0, bytes.length - dropBytes);

Uint8List _manifestWithField(
  String field,
  Object? value, {
  String root = 'passione-dist',
  String manifestName = 'skin-manifest.json',
}) {
  final manifest = <String, dynamic>{
    'id': root,
    'name': 'Passione',
    'version': '1.0.0',
  }..[field] = value;
  return _encoded([
    ArchiveFile.string('$root/index.html', '<html></html>'),
    ArchiveFile.string('$root/$manifestName', jsonEncode(manifest)),
  ]);
}

class _TestStorage extends WebUIStorage {
  _TestStorage(super.settingsController, {required this.webUIDir});

  final Directory webUIDir;

  @override
  Future<List<RemoteUpdateItemResult>> checkRemoteBundledSkins() async =>
      const [];
}

class _FailingCopyStorage extends _TestStorage {
  _FailingCopyStorage(super.settingsController, {required super.webUIDir});

  int copyAttempts = 0;

  @override
  Future<void> copySkinFiles(Directory source, Directory destination) async {
    copyAttempts++;
    await super.copySkinFiles(source, destination);
    throw const FileSystemException('simulated copy failure');
  }
}

class _FailingMoveStorage extends _TestStorage {
  _FailingMoveStorage(
    super.settingsController, {
    required super.webUIDir,
    required this.destination,
  });

  final String destination;

  @override
  Future<void> moveSkinDirectory(Directory source, Directory target) async {
    if (target.path == destination &&
        paths.basename(source.path).startsWith('candidate_')) {
      throw const FileSystemException('simulated rename failure');
    }
    await super.moveSkinDirectory(source, target);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late Directory webUIDir;
  late SettingsController settings;

  setUp(() async {
    tmpRoot = Directory.systemTemp.createTempSync('webui_archive_safety');
    webUIDir = Directory('${tmpRoot.path}/web-ui');
    settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
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
          (_) async => tmpRoot.path,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    rootBundle.evict(_sourcesAsset);
    rootBundle.evict(_bundledManifestAsset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  WebUIStorage newStorage() {
    final storage = _TestStorage(settings, webUIDir: webUIDir);
    storage.debugInitWithWebUIDir(webUIDir);
    return storage;
  }

  Future<WebUIStorage> reloadedStorage() async {
    final storage = WebUIStorage(
      SettingsController(MockSettingsService()),
      webUIDir: webUIDir,
    );
    await storage.initialize(downloadRemote: false);
    return storage;
  }

  Future<Object?> installFromRemote(
    WebUIStorage storage,
    Uint8List bytes, {
    String url = _alphaUrl,
    String etag = 'etag-1',
  }) async {
    Object? error;
    await http.runWithClient(() async {
      try {
        await storage.installFromUrl(url);
      } catch (e) {
        error = e;
      }
    }, () => _remoteClient({url: bytes}, etag: etag));
    return error;
  }

  Future<RemoteUpdateReport> checkUpdates(
    WebUIStorage storage,
    Map<String, Uint8List> archives, {
    String etag = 'etag-2',
  }) => http.runWithClient(
    () => storage.checkForSkinUpdates(),
    () => _remoteClient(archives, etag: etag),
  );

  Directory installedSkin(String id) => Directory('${webUIDir.path}/$id');

  Map<String, String> snapshot(Directory directory) {
    final entries = <String, String>{};
    for (final entity in directory.listSync(recursive: true)) {
      if (entity is! File) continue;
      entries[paths.relative(entity.path, from: directory.path)] = base64Encode(
        entity.readAsBytesSync(),
      );
    }
    return entries;
  }

  Directory makeSource(String version) {
    final source = Directory('${tmpRoot.path}/src_$version')..createSync();
    File('${source.path}/skin-manifest.json').writeAsStringSync(
      jsonEncode(
        _manifest('passione-dist', name: 'Passione', version: version),
      ),
    );
    File('${source.path}/index.html')
        .writeAsStringSync('<html>$version</html>');
    return source;
  }

  String installedVersion(String id) {
    for (final name in ['skin-manifest.json', 'manifest.json']) {
      final manifest = File('${webUIDir.path}/$id/$name');
      if (manifest.existsSync()) {
        final json = jsonDecode(manifest.readAsStringSync());
        return (json as Map<String, dynamic>)['version'] as String;
      }
    }
    fail('no manifest for $id');
  }

  List<Directory> stagingDirectories() => webUIDir
      .listSync()
      .whereType<Directory>()
      .where((dir) => paths.basename(dir.path) == '.webui-install-staging')
      .toList();

  List<Directory> extractionDirectories() => tmpRoot
      .listSync()
      .whereType<Directory>()
      .where((dir) => paths.basename(dir.path).startsWith('webui_extract'))
      .toList();

  group('rejected skin archives', () {
    test('an HTTP 200 body that is not a ZIP is rejected', () async {
      final storage = newStorage();
      final error = await installFromRemote(
        storage,
        Uint8List.fromList(utf8.encode('this is not a zip archive at all')),
      );

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(remoteErrorReason(error!), contains('not a valid skin archive'));
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
      expect(extractionDirectories(), isEmpty);
    });

    test('a valid ZIP with zero entries is rejected', () async {
      final storage = newStorage();
      final error = await installFromRemote(storage, _encoded(const []));

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(remoteErrorReason(error!), contains('not a valid skin archive'));
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
    });

    test('a directory-only ZIP is rejected', () async {
      final storage = newStorage();
      final bytes = _encoded([
        ArchiveFile.directory('passione-dist/'),
        ArchiveFile.directory('passione-dist/assets/'),
      ]);
      final error = await installFromRemote(storage, bytes);

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(remoteErrorReason(error!), contains('does not contain any files'));
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
    });

    test('a README-only ZIP is rejected', () async {
      final storage = newStorage();
      final bytes = _encoded([
        ArchiveFile.string('passione-dist/README.md', '# passione'),
      ]);
      final error = await installFromRemote(storage, bytes);

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(
        remoteErrorReason(error!),
        contains('does not contain an index.html'),
      );
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
    });

    test('an archive without index.html at the selected root is rejected'
        ' even when it declares a skin id', () async {
      final storage = newStorage();
      final bytes = _skinArchive(includeIndex: false);
      final error = await installFromRemote(storage, bytes);

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(
        remoteErrorReason(error!),
        contains('does not contain an index.html'),
      );
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
    });

    test('a truncated archive is rejected', () async {
      final storage = newStorage();
      final error = await installFromRemote(
        storage,
        _truncated(_skinArchive(), 10),
      );

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(remoteErrorReason(error!), contains('not a valid skin archive'));
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
    });

    test('an archive with damaged entry content is rejected instead of'
        ' installing a partial skin', () async {
      final storage = newStorage();
      final bytes = _flipStoredByte(
        _encoded([
          ArchiveFile.noCompress(
            'passione-dist/index.html',
            16,
            utf8.encode('SKINBODY_SKINBODY'),
          ),
          ArchiveFile.string(
            'passione-dist/skin-manifest.json',
            jsonEncode(_manifest('passione-dist', version: '1.0.0')),
          ),
        ]),
        'SKINBODY',
      );
      final error = await installFromRemote(storage, bytes);

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(remoteErrorReason(error!), contains('could not be extracted'));
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
      expect(extractionDirectories(), isEmpty);
    });

    test('an archive that fails during extraction is rejected', () async {
      final storage = newStorage();
      final bytes = _encoded([
        ArchiveFile.string('passione-dist/index.html', '<html></html>'),
        ArchiveFile.string('passione-dist/index.html/child.txt', 'conflict'),
      ]);
      final error = await installFromRemote(storage, bytes);

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(remoteErrorReason(error!), contains('could not be extracted'));
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
    });

    test('an archive with a valid index.html and an empty-path entry is'
        ' rejected instead of installing a partial skin', () async {
      final storage = newStorage();
      final bytes = _encoded([
        ArchiveFile.string('passione-dist/index.html', '<html></html>'),
        ArchiveFile.string('', 'junk'),
      ]);
      final error = await installFromRemote(storage, bytes);

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(remoteErrorReason(error!), contains('could not be extracted'));
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
      expect(extractionDirectories(), isEmpty);
    });

    test('a manifest that is not valid JSON is rejected', () async {
      final storage = newStorage();
      final bytes = _encoded([
        ArchiveFile.string('passione-dist/index.html', '<html></html>'),
        ArchiveFile.string('passione-dist/skin-manifest.json', '{"id": '),
      ]);
      final error = await installFromRemote(storage, bytes);

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(remoteErrorReason(error!), contains('not valid JSON'));
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
    });

    test('a manifest that is not a JSON object is rejected', () async {
      final storage = newStorage();
      final bytes = _encoded([
        ArchiveFile.string('passione-dist/index.html', '<html></html>'),
        ArchiveFile.string(
          'passione-dist/skin-manifest.json',
          jsonEncode(['passione-dist']),
        ),
      ]);
      final error = await installFromRemote(storage, bytes);

      expect(error, isA<UserFacingException>(), reason: 'actual: $error');
      expect(remoteErrorReason(error!), contains('not valid JSON'));
      expect(storage.installedSkins, isEmpty);
      expect(webUIDir.listSync(), isEmpty);
    });

    for (final field in const ['id', 'name', 'description', 'version']) {
      test('a manifest whose $field is not a string is rejected', () async {
        for (final manifestName in const [
          'skin-manifest.json',
          'manifest.json',
        ]) {
          final storage = newStorage();
          final error = await installFromRemote(
            storage,
            _manifestWithField(field, 2, manifestName: manifestName),
          );

          expect(
            error,
            isA<UserFacingException>(),
            reason: '$manifestName actual: $error',
          );
          expect(
            remoteErrorReason(error!),
            contains('invalid "$field" value'),
            reason: manifestName,
          );
          expect(storage.installedSkins, isEmpty, reason: manifestName);
          expect(webUIDir.listSync(), isEmpty, reason: manifestName);
        }
      });
    }
  });

  group('atomic replacement', () {
    test('a larger manifest version and content replace the installed skin'
        ' and leave no staging directories behind', () async {
      final storage = newStorage();
      await storage.installFromPath(makeSource('1.0.0').path);
      expect(installedVersion('passione-dist'), '1.0.0');

      await storage.installFromPath(makeSource('2.0.0').path);

      expect(installedVersion('passione-dist'), '2.0.0');
      expect(
        File('${webUIDir.path}/passione-dist/index.html').readAsStringSync(),
        '<html>2.0.0</html>',
      );
      expect(stagingDirectories(), isEmpty);
      expect(
        webUIDir.listSync().whereType<Directory>().map(
          (dir) => paths.basename(dir.path),
        ),
        ['passione-dist'],
      );

      final reloaded = await reloadedStorage();
      expect(reloaded.installedSkins.map((skin) => skin.id), ['passione-dist']);
    });

    test('a copy failure while staging keeps the previous skin', () async {
      final storage = newStorage();
      await storage.installFromPath(makeSource('1.0.0').path);
      final before = snapshot(installedSkin('passione-dist'));

      final failing = _FailingCopyStorage(settings, webUIDir: webUIDir)
        ..debugInitWithWebUIDir(webUIDir);
      await expectLater(
        failing.installFromPath(makeSource('2.0.0').path),
        throwsA(isA<FileSystemException>()),
      );

      expect(failing.copyAttempts, 1);
      expect(snapshot(installedSkin('passione-dist')), before);
      expect(installedVersion('passione-dist'), '1.0.0');
      expect(stagingDirectories(), isEmpty);
    });

    test(
      'a rename failure during replacement restores the previous skin',
      () async {
        final storage = newStorage();
        await storage.installFromPath(makeSource('1.0.0').path);
        final before = snapshot(installedSkin('passione-dist'));

        final failing = _FailingMoveStorage(
          settings,
          webUIDir: webUIDir,
          destination: installedSkin('passione-dist').path,
        )..debugInitWithWebUIDir(webUIDir);
        await expectLater(
          failing.installFromPath(makeSource('2.0.0').path),
          throwsA(isA<FileSystemException>()),
        );

        expect(snapshot(installedSkin('passione-dist')), before);
        expect(installedVersion('passione-dist'), '1.0.0');
        expect(stagingDirectories(), isEmpty);

        final reloaded = await reloadedStorage();
        expect(reloaded.installedSkins.map((skin) => skin.id), [
          'passione-dist',
        ]);
        expect(
          File('${webUIDir.path}/passione-dist/index.html').readAsStringSync(),
          '<html>1.0.0</html>',
        );
      },
    );

    test('a rejected update of an installed skin keeps the working skin,'
        ' its version and its metadata', () async {
      final storage = newStorage();
      final installed = await installFromRemote(storage, _skinArchive());
      expect(installed, isNull);
      expect(installedVersion('passione-dist'), '1.0.0');
      final before = snapshot(installedSkin('passione-dist'));

      final report = await checkUpdates(storage, {
        _alphaUrl: _encoded([
          ArchiveFile.string('passione-dist/README.md', '# broken download'),
        ]),
      });

      expect(report.hasFailures, isTrue);
      final result = report.results.single;
      expect(result.item, 'passione-dist');
      expect(result.status, RemoteUpdateStatus.failed);
      expect(result.error, isA<UserFacingException>());

      expect(snapshot(installedSkin('passione-dist')), before);
      expect(installedVersion('passione-dist'), '1.0.0');
      final metadata = storage.getSkin('passione-dist')!.reaMetadata!;
      expect(metadata.sourceUrl, _alphaUrl);
      expect(metadata.etag, 'etag-1');
      expect(stagingDirectories(), isEmpty);

      final reloaded = await reloadedStorage();
      expect(reloaded.installedSkins.map((skin) => skin.id), ['passione-dist']);
      expect(reloaded.getSkin('passione-dist'), isNotNull);
    });

    test(
      'a leftover staging container is never reported as an installed skin',
      () async {
        final leftover = Directory(
          '${webUIDir.path}/.webui-install-staging/previous_passione-dist',
        )..createSync(recursive: true);
        File(
          '${leftover.path}/skin-manifest.json',
        ).writeAsStringSync(jsonEncode(_manifest('ghost-skin', name: 'Ghost')));
        File('${leftover.path}/index.html')
            .writeAsStringSync('<html>ghost</html>');

        final storage = newStorage();
        await storage.installFromPath(makeSource('1.0.0').path);

        expect(storage.getSkin('ghost-skin'), isNull);
        expect(storage.installedSkins.map((skin) => skin.id), [
          'passione-dist',
        ]);

        final reloaded = await reloadedStorage();
        expect(reloaded.getSkin('ghost-skin'), isNull);
        expect(reloaded.installedSkins.map((skin) => skin.id), [
          'passione-dist',
        ]);
      },
    );
  });

  group('accepted skin archives', () {
    test('index.html plus skin-manifest.json installs', () async {
      final storage = newStorage();
      final error = await installFromRemote(
        storage,
        _skinArchive(
          manifest: _manifest(
            'passione-dist',
            name: 'Passione',
            version: '1.0.0',
          ),
        ),
      );

      expect(error, isNull);
      expect(installedVersion('passione-dist'), '1.0.0');
      expect(
        File('${webUIDir.path}/passione-dist/index.html').readAsStringSync(),
        '<html>skin</html>',
      );
    });

    test('index.html plus manifest.json installs with its version', () async {
      final storage = newStorage();
      final error = await installFromRemote(
        storage,
        _skinArchive(
          manifestName: 'manifest.json',
          manifest: _manifest(
            'passione-dist',
            name: 'Passione',
            version: '2.0.4',
          ),
        ),
      );

      expect(error, isNull);
      expect(installedVersion('passione-dist'), '2.0.4');
      expect(storage.getSkin('passione-dist')!.version, '2.0.4');
    });

    test(
      'a manifestless legacy index.html installs under the archive root',
      () async {
        final storage = newStorage();
        final error = await installFromRemote(
          storage,
          _encoded([
            ArchiveFile.string('legacy-skin/index.html', '<html>legacy</html>'),
          ]),
        );

        expect(error, isNull);
        expect(storage.getSkin('legacy-skin'), isNotNull);
        expect(storage.getSkin('legacy-skin')!.version, isNull);
        expect(
          File('${webUIDir.path}/legacy-skin/index.html').readAsStringSync(),
          '<html>legacy</html>',
        );
      },
    );

    test('an archive rooted at the ZIP top level still installs', () async {
      final storage = newStorage();
      final error = await installFromRemote(
        storage,
        _encoded([
          ArchiveFile.string('index.html', '<html>flat</html>'),
          ArchiveFile.string(
            'skin-manifest.json',
            jsonEncode(_manifest('flat-skin', name: 'Flat', version: '3.0.0')),
          ),
        ]),
      );

      expect(error, isNull);
      expect(installedVersion('flat-skin'), '3.0.0');
    });

    test(
      'a manifest with null name, description and version still installs',
      () async {
        final storage = newStorage();
        final error = await installFromRemote(
          storage,
          _skinArchive(
            manifest: const <String, dynamic>{
              'id': 'passione-dist',
              'name': null,
              'description': null,
              'version': null,
            },
          ),
        );

        expect(error, isNull);
        final skin = storage.getSkin('passione-dist');
        expect(skin, isNotNull);
        expect(skin!.name, 'passione-dist');
        expect(skin.description, isNull);
        expect(skin.version, isNull);
        expect(
          File('${webUIDir.path}/passione-dist/index.html').existsSync(),
          isTrue,
        );

        final reloaded = await reloadedStorage();
        expect(reloaded.installedSkins.map((skin) => skin.id), [
          'passione-dist',
        ]);
      },
    );
  });

  group('mixed skin update batches', () {
    test('an unusable archive fails only its own item', () async {
      final storage = newStorage();
      final alpha = await installFromRemote(
        storage,
        _skinArchive(
          root: 'alpha',
          manifest: _manifest('alpha', name: 'Alpha', version: '1.0.0'),
        ),
      );
      expect(alpha, isNull);
      final beta = await installFromRemote(
        storage,
        _skinArchive(
          root: 'beta',
          manifest: _manifest('beta', name: 'Beta', version: '1.0.0'),
        ),
        url: _betaUrl,
      );
      expect(beta, isNull);
      final alphaBefore = snapshot(installedSkin('alpha'));

      final report = await checkUpdates(storage, {
        _alphaUrl: _encoded([
          ArchiveFile.string('alpha/README.md', '# broken download'),
        ]),
        _betaUrl: _skinArchive(
          root: 'beta',
          manifest: _manifest('beta', name: 'Beta', version: '2.0.0'),
        ),
      });

      expect(report.results.map((result) => result.item), ['alpha', 'beta']);
      expect(report.results.first.status, RemoteUpdateStatus.failed);
      expect(report.results.first.error, isA<UserFacingException>());
      expect(report.results.last.status, RemoteUpdateStatus.updated);
      expect(installedVersion('beta'), '2.0.0');
      expect(snapshot(installedSkin('alpha')), alphaBefore);
      expect(installedVersion('alpha'), '1.0.0');
      expect(storage.installedSkins.map((skin) => skin.id).toSet(), {
        'alpha',
        'beta',
      });
    });
  });
}

MockClient _remoteClient(
  Map<String, Uint8List> archives, {
  required String etag,
}) {
  return MockClient((request) async {
    final url = request.url.toString();
    final bytes = archives[url];
    if (bytes == null) return http.Response('not found: $url', 404);
    if (request.method == 'HEAD') {
      return http.Response('', 200, headers: {'etag': etag});
    }
    return http.Response.bytes(bytes, 200, headers: {'etag': etag});
  });
}
