import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/util/remote_update_report.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

import 'helpers/mock_settings_service.dart';

class _OrderedDirectory extends Fake implements Directory {
  _OrderedDirectory(this.directory, {required this.reverse});

  final Directory directory;
  final bool reverse;
  void Function()? onList;

  @override
  String get path => directory.path;

  @override
  bool existsSync() => directory.existsSync();

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    onList?.call();
    final entries = directory.listSync(
      recursive: recursive,
      followLinks: followLinks,
    )..sort((a, b) => a.path.compareTo(b.path));
    return reverse ? entries.reversed.toList() : entries;
  }
}

class _LocalStorage extends WebUIStorage {
  _LocalStorage(super.settingsController);

  @override
  Future<List<RemoteUpdateItemResult>> checkRemoteBundledSkins() async => [];
}

void main() {
  late Directory root;
  late SettingsController settings;
  final services = <WebUIService>[];

  setUp(() async {
    WebUIService.resolveWifiIP = () async => 'localhost';
    root = Directory.systemTemp.createTempSync('webui_legacy_selection_');
    settings = SettingsController(MockSettingsService());
    await settings.loadSettings();
  });

  tearDown(() async {
    for (final service in services) {
      await service.stopServing();
    }
    services.clear();
    WebUIService.resolveWifiIP = NetworkInfo().getWifiIP;
    await root.delete(recursive: true);
  });

  WebUIService createService({
    Future<Map<String, int>> Function()? load,
    Future<void> Function(Map<String, int>)? save,
  }) {
    final service = WebUIService(
      listLocalAddresses: () async => [],
      loadSkinPortAssignments: load,
      saveSkinPortAssignments: save,
    );
    services.add(service);
    return service;
  }

  Future<int> legacyPort(Directory legacy) async {
    final previous = createService();
    await previous.serveFolderAtPath(legacy.path, port: 0);
    final port = previous.port;
    await previous.stopServing();
    return port;
  }

  Future<String> servedBody(WebUIService service) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://localhost:${service.port}/'),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      return await response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  Directory seed(String folder, String version, {String id = 'streamline.js'}) {
    final dir = Directory('${root.path}/$folder')..createSync();
    File(
      '${dir.path}/skin-manifest.json',
    ).writeAsStringSync(jsonEncode({'id': id, 'name': id, 'version': version}));
    File('${dir.path}/index.html').writeAsStringSync('<html>$version</html>');
    return dir;
  }

  Future<WebUIStorage> scan({bool reverse = false}) async {
    final storage = _LocalStorage(settings)
      ..debugInitWithWebUIDir(_OrderedDirectory(root, reverse: reverse));
    await storage.downloadRemoteSkinsAndRescan();
    return storage;
  }

  for (final reverse in [false, true]) {
    test('canonical skin wins with reverse discovery $reverse', () async {
      final legacy = seed('streamline_project-main', '0.2.27');
      final canonical = seed('streamline.js', '0.2.28');
      final legacyIndex = File('${legacy.path}/index.html').readAsStringSync();

      final storage = await scan(reverse: reverse);

      expect(storage.installedSkins, hasLength(1));
      expect(storage.getSkin('streamline.js')?.path, canonical.path);
      expect(storage.defaultSkin?.path, canonical.path);
      expect(storage.defaultSkin?.version, '0.2.28');
      expect(File('${legacy.path}/index.html').readAsStringSync(), legacyIndex);
    });
  }

  test(
    'current files use the legacy origin across migration and restart',
    () async {
      final legacy = seed('streamline_project-main', '0.2.27');
      final canonical = seed('streamline.js', '0.2.28');
      final port = await legacyPort(legacy);
      var saved = {legacy.path: port};
      final storage = await scan();
      final service = createService(
        load: () async => Map.of(saved),
        save: (assignments) async => saved = assignments,
      )..legacySkinPathsProvider = storage.legacySkinPaths;

      await service.serveFolderAtPath(storage.defaultSkin!.path, port: 0);

      expect(service.port, port);
      expect(await servedBody(service), contains('0.2.28'));
      expect(saved, {canonical.path: port});
      expect(
        File('${legacy.path}/index.html').readAsStringSync(),
        '<html>0.2.27</html>',
      );
      await service.stopServing();

      final reopened = await scan(reverse: true);
      final relaunched = createService(load: () async => Map.of(saved))
        ..legacySkinPathsProvider = reopened.legacySkinPaths;
      await relaunched.serveFolderAtPath(reopened.defaultSkin!.path, port: 0);
      expect(relaunched.port, port);
      expect(await servedBody(relaunched), contains('0.2.28'));
    },
  );

  test(
    'an existing canonical assignment is never replaced by a legacy port',
    () async {
      final legacy = seed('streamline_project-main', '0.2.27');
      final canonical = seed('streamline.js', '0.2.28');
      final port = await legacyPort(legacy);
      final current = createService();
      await current.serveFolderAtPath(canonical.path, port: 0);
      final canonicalPort = current.port;
      await current.stopServing();
      final original = {legacy.path: port, canonical.path: canonicalPort};
      var saves = 0;
      final storage = await scan();
      final service = createService(
        load: () async => Map.of(original),
        save: (_) async => saves++,
      )..legacySkinPathsProvider = storage.legacySkinPaths;

      await service.serveFolderAtPath(canonical.path, port: 0);

      expect(service.port, canonicalPort);
      expect(saves, 0);
      expect(await servedBody(service), contains('0.2.28'));
    },
  );

  test('migration never takes an unrelated skin port', () async {
    seed('streamline_project-main', '0.2.27');
    final canonical = seed('streamline.js', '0.2.28');
    final unrelated = seed('other.skin', '1.0.0', id: 'other.skin');
    final port = await legacyPort(unrelated);
    var saved = {unrelated.path: port};
    final storage = await scan();
    final service = createService(
      load: () async => Map.of(saved),
      save: (assignments) async => saved = assignments,
    )..legacySkinPathsProvider = storage.legacySkinPaths;

    await service.serveFolderAtPath(canonical.path, port: 0);

    expect(service.port, isNot(port));
    expect(saved[unrelated.path], port);
    expect(saved[canonical.path], service.port);
    expect(storage.legacySkinPaths(unrelated.path), isEmpty);
    expect(storage.legacySkinPaths('${root.path}/unknown'), isEmpty);
  });

  test(
    'a busy legacy port keeps its assignment and recovers after release',
    () async {
      final legacy = seed('streamline_project-main', '0.2.27');
      final canonical = seed('streamline.js', '0.2.28');
      final port = await legacyPort(legacy);
      var saved = {legacy.path: port};
      final squatter = await ServerSocket.bind('0.0.0.0', port);
      addTearDown(squatter.close);
      final storage = await scan();
      final service = createService(
        load: () async => Map.of(saved),
        save: (assignments) async => saved = assignments,
      )..legacySkinPathsProvider = storage.legacySkinPaths;

      await service.serveFolderAtPath(canonical.path, port: 0);

      expect(service.port, isNot(port));
      expect(saved, {canonical.path: port});
      await service.stopServing();
      await squatter.close();
      await service.serveFolderAtPath(canonical.path, port: 0);
      expect(service.port, port);
    },
  );

  test('failed persistence still serves the legacy origin and retries after restart', () async {
    final legacy = seed('streamline_project-main', '0.2.27');
    final canonical = seed('streamline.js', '0.2.28');
    final port = await legacyPort(legacy);
    final storage = await scan();
    var attempts = 0;
    final service = createService(
      load: () async => {legacy.path: port},
      save: (_) async {
        attempts++;
        throw const FileSystemException('save failed');
      },
    )..legacySkinPathsProvider = storage.legacySkinPaths;

    await service.serveFolderAtPath(canonical.path, port: 0);
    expect(service.port, port);
    expect(await servedBody(service), contains('0.2.28'));
    await service.stopServing();

    final relaunched = createService(
      load: () async => {legacy.path: port},
      save: (_) async => attempts++,
    )..legacySkinPathsProvider = storage.legacySkinPaths;
    await relaunched.serveFolderAtPath(canonical.path, port: 0);
    expect(relaunched.port, port);
    expect(attempts, 2);
  });

  test(
    'a rescan keeps the previous selection visible until discovery completes',
    () async {
      final legacy = seed('streamline_project-main', '0.2.27');
      final directory = _OrderedDirectory(root, reverse: false);
      final storage = _LocalStorage(settings)..debugInitWithWebUIDir(directory);
      await storage.downloadRemoteSkinsAndRescan();
      final canonical = seed('streamline.js', '0.2.28');
      String? pathDuringScan;
      directory.onList = () => scheduleMicrotask(() {
        pathDuringScan = storage.defaultSkin?.path;
      });

      await storage.downloadRemoteSkinsAndRescan();

      expect(pathDuringScan, legacy.path);
      expect(storage.defaultSkin?.path, canonical.path);
      expect(storage.legacySkinPaths(canonical.path), [legacy.path]);
    },
  );

  test(
    'competing legacy assignments follow the previous discovery preference',
    () async {
      final earlier = seed('streamline_project-dist', '0.2.26');
      final later = seed('streamline_project-main', '0.2.27');
      final canonical = seed('streamline.js', '0.2.28');
      final earlierPort = await legacyPort(earlier);
      final previous = createService(
        load: () async => {earlier.path: earlierPort},
      );
      await previous.serveFolderAtPath(later.path, port: 0);
      final laterPort = previous.port;
      await previous.stopServing();
      var saved = {earlier.path: earlierPort, later.path: laterPort};
      final storage = await scan();
      final service = createService(
        load: () async => Map.of(saved),
        save: (assignments) async => saved = assignments,
      )..legacySkinPathsProvider = storage.legacySkinPaths;

      await service.serveFolderAtPath(canonical.path, port: 0);

      expect(service.port, laterPort);
      expect(saved, {earlier.path: earlierPort, canonical.path: laterPort});
    },
  );

  test('a legacy-only installation remains selectable and untouched', () async {
    final legacy = seed('streamline_project-main', '0.2.27');
    final storage = await scan();

    expect(storage.installedSkins, hasLength(1));
    expect(storage.defaultSkin?.path, legacy.path);
    expect(storage.defaultSkin?.version, '0.2.27');
    expect(
      File('${legacy.path}/index.html').readAsStringSync(),
      '<html>0.2.27</html>',
    );
  });
}
