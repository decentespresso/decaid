import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';

class _FakeKeyValueStore implements KeyValueStoreService {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> set({
    String namespace = 'default',
    required String key,
    required Object value,
  }) async {}

  @override
  Future<bool> delete({
    String namespace = 'default',
    required String key,
  }) async => false;

  @override
  Future<Object?> get({
    String namespace = 'default',
    required String key,
  }) async => null;

  @override
  Future<List<String>> keys({String namespace = 'default'}) async => [];

  @override
  List<String> get namespaces => [];

  @override
  Future<Map<String, Object>> getAll({String namespace = 'default'}) async =>
      {};
}

void main() {
  test(
    'Visualizer upload encodes state_change as non-zero stage markers',
    () async {
      final pluginSource = File(
        'assets/plugins/visualizer.reaplugin/plugin.js',
      ).readAsStringSync();
      final manifest = PluginManifest.fromJson(
        jsonDecode(
              File(
                'assets/plugins/visualizer.reaplugin/manifest.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      final shot = {
        'id': 'shot-1',
        'annotations': <String, dynamic>{},
        'workflow': {
          'profile': {'target_weight': 36},
          'context': <String, dynamic>{},
        },
        'measurements': [
          for (var i = 0; i < 4; i++)
            {
              'machine': {
                'timestamp': '2026-01-01T00:00:0${i * 2}Z',
                'state': {'substate': 'pouring'},
                'profileFrame': [0, 0, 1, 2][i],
                'pressure': 9,
                'targetPressure': 9,
                'flow': 2,
                'targetFlow': 2,
                'mixTemperature': 93,
                'groupTemperature': 92,
                'targetGroupTemperature': 93,
                'targetMixTemperature': 93,
              },
              'scale': {'weight': i * 10, 'weightFlow': 2},
            },
        ],
      };
      final manager = PluginManager(kvStore: _FakeKeyValueStore());
      final setupResult = manager.js.evaluate('''
      globalThis.__timerSet = (pluginId, generation, callback, delay) => { callback(); return 1; };
      globalThis.__timerClear = () => {};
      globalThis.__fetchFor = async (pluginId, generation, url, init = {}) => {
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1')) {
          return { ok: true, json: async () => (${jsonEncode(shot)}) };
        }
        if (url.endsWith('/shots/upload')) {
          const body = init.body;
          const start = body.indexOf('\\r\\n\\r\\n') + 4;
          const end = body.lastIndexOf('\\r\\n--');
          globalThis.__visualizerUpload = JSON.parse(body.slice(start, end));
          return { ok: true, json: async () => ({ id: 'visualizer-1' }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');
      expect(setupResult.isError, isFalse, reason: setupResult.stringResult);

      await manager.loadPlugin(
        id: manifest.id,
        manifest: manifest,
        settings: {
          'Username': 'user',
          'Password': 'password',
          'LengthThreshold': 0,
        },
        jsCode: pluginSource,
      );
      manager.dispatchEvent(manifest.id, 'stateUpdate', {
        'state': {'state': 'espresso'},
      });
      manager.dispatchEvent(manifest.id, 'stateUpdate', {
        'state': {'state': 'idle'},
      });

      Map<String, dynamic>? upload;
      for (var i = 0; i < 20 && upload == null; i++) {
        manager.js.executePendingJob();
        final result = manager.js.evaluate(
          'JSON.stringify(globalThis.__visualizerUpload ?? null)',
        );
        upload = jsonDecode(result.stringResult) as Map<String, dynamic>?;
        await Future<void>.delayed(Duration.zero);
      }

      expect(upload?['state_change'], [1, 1, 2, 3]);
    },
  );

  test(
    'Visualizer upload forwards recipe and shot-review tags',
    () async {
      final pluginSource = File(
        'assets/plugins/visualizer.reaplugin/plugin.js',
      ).readAsStringSync();
      final manifest = PluginManifest.fromJson(
        jsonDecode(
              File(
                'assets/plugins/visualizer.reaplugin/manifest.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      final shot = {
        'id': 'shot-1',
        'annotations': <String, dynamic>{
          'extras': {
            'tags': ['bright'],
          },
        },
        'workflow': {
          'profile': {'target_weight': 36},
          'context': {
            'extras': {
              'tags': ['fast shot', 'washed'],
            },
          },
        },
        'measurements': [
          for (var i = 0; i < 4; i++)
            {
              'machine': {
                'timestamp': '2026-01-01T00:00:0${i * 2}Z',
                'state': {'substate': 'pouring'},
                'profileFrame': [0, 0, 1, 2][i],
                'pressure': 9,
                'targetPressure': 9,
                'flow': 2,
                'targetFlow': 2,
                'mixTemperature': 93,
                'groupTemperature': 92,
                'targetGroupTemperature': 93,
                'targetMixTemperature': 93,
              },
              'scale': {'weight': i * 10, 'weightFlow': 2},
            },
        ],
      };
      final manager = PluginManager(kvStore: _FakeKeyValueStore());
      final setupResult = manager.js.evaluate('''
      globalThis.setTimeout = (callback) => { callback(); return 1; };
      globalThis.clearTimeout = () => {};
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1')) {
          return { ok: true, json: async () => (${jsonEncode(shot)}) };
        }
        if (url.endsWith('/shots/upload')) {
          const body = init.body;
          const start = body.indexOf('\\r\\n\\r\\n') + 4;
          const end = body.lastIndexOf('\\r\\n--');
          globalThis.__visualizerUpload = JSON.parse(body.slice(start, end));
          return { ok: true, json: async () => ({ id: 'visualizer-1' }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');
      expect(setupResult.isError, isFalse, reason: setupResult.stringResult);

      await manager.loadPlugin(
        id: manifest.id,
        manifest: manifest,
        settings: {
          'Username': 'user',
          'Password': 'password',
          'LengthThreshold': 0,
        },
        jsCode: pluginSource,
      );
      manager.dispatchEvent(manifest.id, 'stateUpdate', {
        'state': {'state': 'espresso'},
      });
      manager.dispatchEvent(manifest.id, 'stateUpdate', {
        'state': {'state': 'idle'},
      });

      Map<String, dynamic>? upload;
      for (var i = 0; i < 20 && upload == null; i++) {
        manager.js.executePendingJob();
        final result = manager.js.evaluate(
          'JSON.stringify(globalThis.__visualizerUpload ?? null)',
        );
        upload = jsonDecode(result.stringResult) as Map<String, dynamic>?;
        await Future<void>.delayed(Duration.zero);
      }

      final settings =
          upload?['app']?['data']?['settings'] as Map<String, dynamic>?;
      expect(settings?['tags'], ['fast shot', 'washed', 'bright']);
    },
  );
}
