import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../plugins/plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PUT /api/v1/plugins/<id>/source', () {
    late Directory tempDir;
    late PluginLoaderService service;
    late Handler handler;

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

    const brokenJs = 'function createPlugin() { throw new Error("boom"); }';

    Future<Response> put(String id, Object body) async => handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/api/v1/plugins/$id/source'),
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      ),
    );

    Future<Directory> installSource(
      String id, {
      String version = '1.0.0',
    }) async {
      final dir = Directory('${tempDir.path}/source_$id')
        ..createSync(recursive: true);
      File(
        '${dir.path}/manifest.json',
      ).writeAsStringSync(jsonEncode(manifestJson(id, version: version)));
      File('${dir.path}/plugin.js').writeAsStringSync(pluginJs(id));
      await service.addPlugin(dir.path);
      return dir;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('plugins_handler_update');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tempDir.path,
          );
      service = PluginLoaderService(kvStore: FakeKeyValueStoreService());
      await service.initialize();
      final app = Router().plus;
      PluginsHandler(
        pluginManager: service.pluginManager,
        pluginService: service,
      ).addRoutes(app);
      handler = app.call;
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

    test('overwrites the source of an installed plugin', () async {
      const id = 'update.reaplugin';
      await installSource(id);

      final res = await put(id, {
        'manifest': manifestJson(id, version: '2.0.0'),
        'plugin': '// v2\n${pluginJs(id)}',
      });

      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString());
      expect(body, containsPair('id', id));
      expect(body, containsPair('version', '2.0.0'));
      expect(service.getPluginManifest(id)?.version, '2.0.0');
      expect(
        File('${tempDir.path}/plugins/$id/plugin.js').readAsStringSync(),
        startsWith('// v2'),
      );
    });

    test('keeps files the update does not carry', () async {
      const id = 'assets.reaplugin';
      await installSource(id);
      final asset = File('${tempDir.path}/plugins/$id/assets/logo.svg')
        ..createSync(recursive: true)
        ..writeAsStringSync('<svg/>');

      final res = await put(id, {
        'manifest': manifestJson(id, version: '1.1.0'),
        'plugin': pluginJs(id),
      });

      expect(res.statusCode, 200);
      expect(asset.existsSync(), isTrue);
      expect(asset.readAsStringSync(), '<svg/>');
    });

    test('keeps settings and the auto-load preference', () async {
      const id = 'settings.reaplugin';
      final dir = Directory('${tempDir.path}/source_settings')
        ..createSync(recursive: true);
      File('${dir.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          ...manifestJson(id),
          'settings': {
            'Token': {'type': 'string'},
          },
        }),
      );
      File('${dir.path}/plugin.js').writeAsStringSync(pluginJs(id));
      await service.addPlugin(dir.path);
      await service.savePluginSettings(id, {'Token': 'abc'});
      await service.setPluginAutoLoad(id, true);

      final res = await put(id, {
        'manifest': {
          ...manifestJson(id, version: '1.2.0'),
          'settings': {
            'Token': {'type': 'string'},
          },
        },
        'plugin': pluginJs(id),
      });

      expect(res.statusCode, 200);
      expect(await service.pluginSettings(id), containsPair('Token', 'abc'));
      expect(await service.shouldAutoLoad(id), isTrue);
    });

    test('installs a plugin that is not present yet', () async {
      const id = 'fresh.reaplugin';

      final res = await put(id, {
        'manifest': manifestJson(id),
        'plugin': pluginJs(id),
      });

      expect(res.statusCode, 200);
      expect(service.getPluginManifest(id), isNotNull);
    });

    test('reloads a plugin that was loaded before the update', () async {
      const id = 'loaded.reaplugin';
      await installSource(id);
      await service.loadPlugin(id);

      final res = await put(id, {
        'manifest': manifestJson(id, version: '1.1.0'),
        'plugin': pluginJs(id),
      });

      expect(res.statusCode, 200);
      expect(
        jsonDecode(await res.readAsString()),
        containsPair('loaded', true),
      );
      expect(service.isPluginLoaded(id), isTrue);
    });

    test('leaves an unloaded plugin unloaded', () async {
      const id = 'unloaded.reaplugin';
      await installSource(id);

      final res = await put(id, {
        'manifest': manifestJson(id),
        'plugin': pluginJs(id),
      });

      expect(res.statusCode, 200);
      expect(
        jsonDecode(await res.readAsString()),
        containsPair('loaded', false),
      );
      expect(service.isPluginLoaded(id), isFalse);
    });

    test(
      'rolls back to the running version when the new source fails to load',
      () async {
        const id = 'rollback.reaplugin';
        await installSource(id);
        await service.loadPlugin(id);

        final res = await put(id, {
          'manifest': manifestJson(id, version: '2.0.0'),
          'plugin': brokenJs,
        });

        expect(res.statusCode, 500);
        expect(service.getPluginManifest(id)?.version, '1.0.0');
        expect(
          File('${tempDir.path}/plugins/$id/plugin.js').readAsStringSync(),
          pluginJs(id),
        );
        expect(
          jsonDecode(
            File(
              '${tempDir.path}/plugins/$id/manifest.json',
            ).readAsStringSync(),
          ),
          containsPair('version', '1.0.0'),
        );
        expect(service.isPluginLoaded(id), isTrue);
      },
    );

    test('rejects a downgrade of an installed plugin', () async {
      const id = 'downgrade.reaplugin';
      await installSource(id, version: '2.0.0');

      final res = await put(id, {
        'manifest': manifestJson(id, version: '1.9.0'),
        'plugin': pluginJs(id),
      });

      expect(res.statusCode, 409);
      expect(service.getPluginManifest(id)?.version, '2.0.0');
    });

    test('accepts an update at the installed version', () async {
      const id = 'same.reaplugin';
      await installSource(id, version: '2.0.0');

      final res = await put(id, {
        'manifest': manifestJson(id, version: '2.0.0'),
        'plugin': '// same version\n${pluginJs(id)}',
      });

      expect(res.statusCode, 200);
      expect(
        File('${tempDir.path}/plugins/$id/plugin.js').readAsStringSync(),
        startsWith('// same version'),
      );
    });

    test('rejects a manifest id that does not match the path', () async {
      final res = await put('path.reaplugin', {
        'manifest': manifestJson('other.reaplugin'),
        'plugin': pluginJs('other.reaplugin'),
      });

      expect(res.statusCode, 400);
      expect(service.getPluginManifest('other.reaplugin'), isNull);
    });

    test('rejects a missing plugin source', () async {
      final res = await put('nosource.reaplugin', {
        'manifest': manifestJson('nosource.reaplugin'),
      });

      expect(res.statusCode, 400);
      expect(service.getPluginManifest('nosource.reaplugin'), isNull);
    });

    test('rejects an invalid manifest', () async {
      final res = await put('bad.reaplugin', {
        'manifest': {'id': 'bad.reaplugin'},
        'plugin': pluginJs('bad.reaplugin'),
      });

      expect(res.statusCode, 400);
      expect(service.getPluginManifest('bad.reaplugin'), isNull);
    });

    test('rejects an unsafe plugin id', () async {
      final res = await put(Uri.encodeComponent('../escape'), {
        'manifest': manifestJson('../escape'),
        'plugin': pluginJs('../escape'),
      });

      expect(res.statusCode, 400);
      expect(Directory('${tempDir.parent.path}/escape').existsSync(), isFalse);
    });
  });
}
