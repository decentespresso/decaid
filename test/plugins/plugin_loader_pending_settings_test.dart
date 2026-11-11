import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_test_helpers.dart';

const _first = 'hook-probe.reaplugin';
const _second = 'hook-bystander.reaplugin';

String _manifest(String id, {required bool withSetting}) => jsonEncode({
  'id': id,
  'author': 'Test',
  'name': id,
  'description': 'Pending settings hook fixture',
  'version': '1.0.0',
  'apiVersion': 1,
  'permissions': <String>[],
  'settings': withSetting
      ? {
          'AutoUpload': {
            'type': 'boolean',
            'description': 'Upload shots automatically',
            'default': false,
          },
        }
      : <String, dynamic>{},
  'api': <Object>[],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tempDir;
  late PluginLoaderService service;

  void install(String id, {required bool withSetting}) {
    final dir = Directory('${tempDir.path}/plugins/$id')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json')
        .writeAsStringSync(_manifest(id, withSetting: withSetting));
    File('${dir.path}/plugin.js').writeAsStringSync('''
function createPlugin(host) {
  return { id: "$id", onLoad() {} };
}
''');
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('plugin_pending_settings');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tempDir.path,
    );
    // No bundled assets for this fixture: the copy pass logs and continues.
    messenger.setMockMessageHandler('flutter/assets', (_) async => null);
    service = PluginLoaderService(kvStore: FakeKeyValueStoreService());
  });

  tearDown(() async {
    await service.dispose();
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    messenger.setMockMessageHandler('flutter/assets', null);
    tempDir.deleteSync(recursive: true);
  });

  test(
    'legacy shot upload preference helper reads only true AutoUpload',
    () async {
      SharedPreferences.setMockInitialValues({
        'plugin.settings.shot-upload.reaplugin': jsonEncode({
          'AutoUpload': true,
        }),
      });
      expect(await persistedShotUploadAutoUploadEnabled(), isTrue);

      SharedPreferences.setMockInitialValues({
        'plugin.settings.shot-upload.reaplugin': jsonEncode({
          'AutoUpload': false,
        }),
      });
      expect(await persistedShotUploadAutoUploadEnabled(), isFalse);

      SharedPreferences.setMockInitialValues({
        'plugin.settings.shot-upload.reaplugin': true,
      });
      expect(await persistedShotUploadAutoUploadEnabled(), isFalse);
    },
  );

  test('the hook runs after the manifest scan and before autoload', () async {
    install(_first, withSetting: true);
    SharedPreferences.setMockInitialValues({'plugin.autoload.$_first': true});
    var loadedWhenHookRan = true;
    var settingsWriteSucceeded = false;
    service.applyPendingSettings = () async {
      loadedWhenHookRan = service.isPluginLoaded(_first);
      await service.savePluginSettings(_first, {'AutoUpload': true});
      settingsWriteSucceeded = true;
    };

    await service.initialize();

    expect(loadedWhenHookRan, isFalse);
    expect(
      settingsWriteSucceeded,
      isTrue,
      reason: 'savePluginSettings needs the manifest scan to have run',
    );
    expect(service.isPluginLoaded(_first), isTrue);
    expect((await service.pluginSettings(_first))['AutoUpload'], isTrue);
  });

  test('a throwing hook does not abort initialization', () async {
    install(_first, withSetting: true);
    SharedPreferences.setMockInitialValues({'plugin.autoload.$_first': true});
    service.applyPendingSettings = () async => throw Exception('boom');

    await service.initialize();

    expect(service.isPluginLoaded(_first), isTrue);
  });

  test('a suppressed plugin fails to load through every path', () async {
    install(_first, withSetting: true);
    install(_second, withSetting: false);
    SharedPreferences.setMockInitialValues({
      'plugin.autoload.$_first': true,
      'plugin.autoload.$_second': true,
    });
    service.applyPendingSettings = () async => service.suppressLoad(_first);

    await service.initialize();

    expect(service.isPluginLoaded(_first), isFalse);
    expect(service.isPluginLoaded(_second), isTrue);
    await expectLater(service.loadPlugin(_first), throwsA(isA<Exception>()));
    await expectLater(service.enablePlugin(_first), throwsA(isA<Exception>()));
    expect(service.isPluginLoaded(_first), isFalse);
    expect(service.isPluginLoaded(_second), isTrue);
  });
}
