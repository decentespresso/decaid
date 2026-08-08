import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;
import 'package:reaprime/src/services/storage/kv_store_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ControllableCredentialStore implements CredentialStore {
  String? _pausedKey;
  Completer<void>? _pauseEntered;
  Completer<void>? _resume;

  void pauseReadFor(String key) {
    _pausedKey = key;
    _pauseEntered = Completer<void>();
    _resume = Completer<void>();
  }

  Future<void> waitUntilPaused() => _pauseEntered!.future;

  void resume() => _resume!.complete();

  @override
  Future<String?> read({required String key}) async {
    if (key == _pausedKey) {
      _pauseEntered!.complete();
      await _resume!.future;
    }
    return null;
  }

  @override
  Future<void> write({required String key, required String value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

class _FakeKvStore implements KeyValueStoreService {
  final Map<String, Map<String, Object>> _store = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<void> set({
    String namespace = 'default',
    required String key,
    required Object value,
  }) async {
    _store.putIfAbsent(namespace, () => {})[key] = value;
  }

  @override
  Future<bool> delete({
    String namespace = 'default',
    required String key,
  }) async => _store[namespace]?.remove(key) != null;

  @override
  Future<Object?> get({
    String namespace = 'default',
    required String key,
  }) async => _store[namespace]?[key];

  @override
  Future<List<String>> keys({String namespace = 'default'}) async =>
      _store[namespace]?.keys.toList() ?? [];

  @override
  List<String> get namespaces => _store.keys.toList();

  @override
  Future<Map<String, Object>> getAll({String namespace = 'default'}) async =>
      Map.from(_store[namespace] ?? {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginId = 'watchdog-test.reaplugin';
  late Directory tempDir;
  late Directory sourceDir;
  late PluginLoaderService service;
  late _ControllableCredentialStore credentialStore;

  void writePlugin(String js) {
    File('${sourceDir.path}/plugin.js').writeAsStringSync(js);
  }

  Future<void> expectLoadFailure() async {
    await expectLater(service.loadPlugin(pluginId), throwsException);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('plugin_watchdog_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempDir.path,
        );

    sourceDir = Directory('${tempDir.path}/source')..createSync();
    File('${sourceDir.path}/manifest.json').writeAsStringSync(
      jsonEncode({
        'id': pluginId,
        'author': 'Test',
        'name': 'Watchdog test',
        'description': 'Test plugin',
        'version': '1.0.0',
        'apiVersion': 1,
        'permissions': <String>[],
        'settings': <String, Object>{},
        'api': <Object>[],
      }),
    );
    writePlugin('function createPlugin() { throw new Error("boom"); }');

    credentialStore = _ControllableCredentialStore();
    service = PluginLoaderService(
      kvStore: _FakeKvStore(),
      credentialStore: credentialStore,
    );
    await service.initialize();
    await service.addPlugin(sourceDir.path);
    await service.setPluginAutoLoad(pluginId, true);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    tempDir.deleteSync(recursive: true);
  });

  test('disables auto-load after three consecutive load failures', () async {
    await expectLoadFailure();
    await expectLoadFailure();
    expect(await service.shouldAutoLoad(pluginId), isTrue);

    await expectLoadFailure();
    expect(await service.shouldAutoLoad(pluginId), isFalse);
  });

  test('missing plugin code also counts as a load failure', () async {
    File('${tempDir.path}/plugins/$pluginId/plugin.js').deleteSync();

    await expectLoadFailure();
    await expectLoadFailure();
    await expectLoadFailure();

    expect(await service.shouldAutoLoad(pluginId), isFalse);
  });

  test('successful load resets the consecutive failure count', () async {
    await expectLoadFailure();
    await expectLoadFailure();

    writePlugin('''
function createPlugin() {
  return { id: "$pluginId", onLoad() {} };
}
''');
    File(
      '${tempDir.path}/plugins/$pluginId/plugin.js',
    ).writeAsStringSync(File('${sourceDir.path}/plugin.js').readAsStringSync());
    await service.loadPlugin(pluginId);

    writePlugin('function createPlugin() { throw new Error("boom"); }');
    File(
      '${tempDir.path}/plugins/$pluginId/plugin.js',
    ).writeAsStringSync(File('${sourceDir.path}/plugin.js').readAsStringSync());
    await expectLoadFailure();
    await expectLoadFailure();

    expect(await service.shouldAutoLoad(pluginId), isTrue);
  });

  test(
    'manually re-enabling auto-load gives the plugin a fresh attempt',
    () async {
      await expectLoadFailure();
      await expectLoadFailure();
      await expectLoadFailure();
      expect(await service.shouldAutoLoad(pluginId), isFalse);

      await service.setPluginAutoLoad(pluginId, true);
      await expectLoadFailure();

      expect(await service.shouldAutoLoad(pluginId), isTrue);
    },
  );

  test('serializes concurrent plugin loads', () async {
    const secondPluginId = 'watchdog-second.reaplugin';
    final secondSource = Directory('${tempDir.path}/second-source')
      ..createSync();
    File('${secondSource.path}/manifest.json').writeAsStringSync(
      jsonEncode({
        'id': secondPluginId,
        'author': 'Test',
        'name': 'Second watchdog test',
        'description': 'Test plugin',
        'version': '1.0.0',
        'apiVersion': 1,
        'permissions': <String>[],
        'settings': <String, Object>{},
        'api': <Object>[],
      }),
    );
    File('${secondSource.path}/plugin.js').writeAsStringSync('''
function createPlugin() {
  return { id: "$secondPluginId", onLoad() {} };
}
''');
    await service.addPlugin(secondSource.path);
    File('${tempDir.path}/plugins/$pluginId/plugin.js').writeAsStringSync('''
function createPlugin() {
  return { id: "$pluginId", onLoad() {} };
}
''');

    credentialStore.pauseReadFor('plugin.settings.secure.$pluginId');
    final firstLoad = service.loadPlugin(pluginId);
    await credentialStore.waitUntilPaused();

    var secondCompleted = false;
    final secondLoad = service
        .loadPlugin(secondPluginId)
        .then((_) => secondCompleted = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(secondCompleted, isFalse);

    credentialStore.resume();
    await Future.wait([firstLoad, secondLoad]);
  });

  test('next launch disables a plugin interrupted during load', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('plugin.watchdog.loading', pluginId);

    final nextLaunch = PluginLoaderService(kvStore: _FakeKvStore());
    await nextLaunch.initialize();

    expect(await nextLaunch.shouldAutoLoad(pluginId), isFalse);
    expect(nextLaunch.isPluginLoaded(pluginId), isFalse);
  });
}
