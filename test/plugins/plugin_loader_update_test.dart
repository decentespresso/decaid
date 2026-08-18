import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginLoaderService source updates', () {
    late Directory tempDir;
    late PluginLoaderService service;

    Map<String, dynamic> manifestJson(String id, {String version = '1.0.0'}) =>
        {
          'id': id,
          'author': 'Test',
          'name': 'Test plugin',
          'description': 'Test plugin',
          'version': version,
          'apiVersion': 1,
          'permissions': <String>[],
          'settings': <String, dynamic>{},
          'api': <Object>[],
        };

    String pluginJs(String id) =>
        '''
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''';

    Future<void> install(String id, {String version = '1.0.0'}) async {
      final dir = Directory('${tempDir.path}/source_${id}_$version')
        ..createSync(recursive: true);
      File(
        '${dir.path}/manifest.json',
      ).writeAsStringSync(jsonEncode(manifestJson(id, version: version)));
      File('${dir.path}/plugin.js').writeAsStringSync(pluginJs(id));
      await service.addPlugin(dir.path);
    }

    Future<void> update(String id, String version) =>
        service.updatePluginSource(
          id,
          manifestJson: manifestJson(id, version: version),
          pluginJs: '// $version\n${pluginJs(id)}',
        );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('plugin_loader_update');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tempDir.path,
          );
      service = PluginLoaderService(kvStore: FakeKeyValueStoreService());
      await service.initialize();
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

    test('addPlugin rejects an older version of an installed plugin', () async {
      const id = 'versioned.reaplugin';
      await install(id, version: '2.0.0');

      await expectLater(
        install(id, version: '1.0.0'),
        throwsA(isA<PluginDowngradeException>()),
      );
      expect(service.getPluginManifest(id)?.version, '2.0.0');
    });

    test('addPlugin accepts the same or a newer version', () async {
      const id = 'versioned.reaplugin';
      await install(id, version: '2.0.0');

      await install(id, version: '2.0.0');
      expect(service.getPluginManifest(id)?.version, '2.0.0');

      await install(id, version: '2.0.1');
      expect(service.getPluginManifest(id)?.version, '2.0.1');
    });

    test('prerelease versions rank below their release', () async {
      const id = 'prerelease.reaplugin';
      await install(id, version: '1.0.0-beta.2');

      await expectLater(
        update(id, '1.0.0-beta.1'),
        throwsA(isA<PluginDowngradeException>()),
      );

      await update(id, '1.0.0');
      expect(service.getPluginManifest(id)?.version, '1.0.0');

      await expectLater(
        update(id, '1.0.0-rc.1'),
        throwsA(isA<PluginDowngradeException>()),
      );
    });

    test('updatePluginSource rejects a manifest id mismatch', () async {
      const id = 'mismatch.reaplugin';
      await install(id);

      await expectLater(
        service.updatePluginSource(
          id,
          manifestJson: manifestJson('other.reaplugin'),
          pluginJs: pluginJs(id),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(service.getPluginManifest('other.reaplugin'), isNull);
    });

    test('concurrent updates apply one at a time', () async {
      const id = 'concurrent.reaplugin';
      await install(id);

      await Future.wait([update(id, '1.1.0'), update(id, '1.2.0')]);

      final onDisk = jsonDecode(
        File('${tempDir.path}/plugins/$id/manifest.json').readAsStringSync(),
      );
      expect(onDisk['version'], '1.2.0');
      expect(service.getPluginManifest(id)?.version, '1.2.0');
      expect(
        File('${tempDir.path}/plugins/$id/plugin.js').readAsStringSync(),
        startsWith('// 1.2.0'),
      );
    });

    test('an update does not interleave with a concurrent unload', () async {
      const id = 'lifecycle.reaplugin';
      await install(id);
      await service.loadPlugin(id);

      await Future.wait([update(id, '1.1.0'), service.unloadPlugin(id)]);

      expect(service.isPluginLoaded(id), isFalse);
      expect(service.getPluginManifest(id)?.version, '1.1.0');
    });

    test('an update does not interleave with a concurrent load', () async {
      const id = 'lifecycle2.reaplugin';
      await install(id);

      await Future.wait([update(id, '1.1.0'), service.loadPlugin(id)]);

      expect(service.isPluginLoaded(id), isTrue);
      expect(service.getPluginManifest(id)?.version, '1.1.0');
    });

    test(
      'a failed write leaves the previous version installed and running',
      () async {
        const id = 'writefail.reaplugin';
        await install(id);
        await service.loadPlugin(id);
        Directory(
          '${tempDir.path}/plugins/$id/plugin.js.staged',
        ).createSync(recursive: true);

        await expectLater(
          update(id, '2.0.0'),
          throwsA(isA<FileSystemException>()),
        );

        expect(service.isPluginLoaded(id), isTrue);
        expect(service.getPluginManifest(id)?.version, '1.0.0');
        final onDisk = jsonDecode(
          File('${tempDir.path}/plugins/$id/manifest.json').readAsStringSync(),
        );
        expect(onDisk['version'], '1.0.0');
        expect(
          File('${tempDir.path}/plugins/$id/plugin.js').readAsStringSync(),
          pluginJs(id),
        );
      },
    );

    test('enablePlugin sets auto-load and loads under one lock', () async {
      const id = 'enable.reaplugin';
      await install(id);

      await service.enablePlugin(id);

      expect(service.isPluginLoaded(id), isTrue);
      expect(await service.shouldAutoLoad(id), isTrue);
    });

    test('enablePlugin leaves auto-load off when the load fails', () async {
      const id = 'enablefail.reaplugin';
      await install(id);
      File('${tempDir.path}/plugins/$id/plugin.js').writeAsStringSync(
        'function createPlugin() { throw new Error("boom"); }',
      );

      await expectLater(service.enablePlugin(id), throwsA(anything));

      expect(service.isPluginLoaded(id), isFalse);
      expect(await service.shouldAutoLoad(id), isFalse);
    });

    test('disablePlugin unloads and clears auto-load under one lock', () async {
      const id = 'disable.reaplugin';
      await install(id);
      await service.enablePlugin(id);

      await service.disablePlugin(id);

      expect(service.isPluginLoaded(id), isFalse);
      expect(await service.shouldAutoLoad(id), isFalse);
    });

    test('concurrent enable/disable end in a consistent state', () async {
      const id = 'togglerace.reaplugin';
      await install(id);

      await Future.wait([
        service.enablePlugin(id),
        service.disablePlugin(id),
        service.enablePlugin(id),
      ]);

      expect(service.isPluginLoaded(id), await service.shouldAutoLoad(id));
    });

    test('enable/disable do not interleave with a concurrent update', () async {
      const id = 'toggleupdate.reaplugin';
      await install(id);

      await Future.wait([
        service.enablePlugin(id),
        update(id, '1.1.0'),
        service.disablePlugin(id),
      ]);

      expect(service.getPluginManifest(id)?.version, '1.1.0');
      expect(service.isPluginLoaded(id), await service.shouldAutoLoad(id));
    });
  });
}
