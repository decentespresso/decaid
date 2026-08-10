import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

final _pluginSource = File(
  'assets/plugins/visualizer.reaplugin/plugin.js',
).readAsStringSync();
final _manifest = PluginManifest.fromJson(
  jsonDecode(
        File(
          'assets/plugins/visualizer.reaplugin/manifest.json',
        ).readAsStringSync(),
      )
      as Map<String, dynamic>,
);

Map<String, dynamic> _shot({
  Map<String, dynamic>? annotations,
  Map<String, dynamic>? context,
}) => {
  'id': 'shot-1',
  'annotations': annotations ?? <String, dynamic>{},
  'workflow': {
    'profile': {'target_weight': 36},
    'context': context ?? <String, dynamic>{},
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

Future<PluginManager> _loadPlugin(
  String fetchSource, {
  Map<String, dynamic> settings = const {},
}) async {
  final manager = PluginManager(kvStore: FakeKeyValueStoreService());
  final setupResult = manager.js.evaluate('''
    globalThis.__testTimers = [];
    globalThis.__nextTimerId = 1;
    globalThis.__timerSet = (pluginId, generation, callback, delay = 0) => {
      if (delay === 5000) {
        callback();
        return 0;
      }
      const timer = { id: globalThis.__nextTimerId++, callback, delay };
      globalThis.__testTimers = [...globalThis.__testTimers, timer];
      return timer.id;
    };
    globalThis.__timerClear = (pluginId, id) => {
      globalThis.__testTimers = globalThis.__testTimers.filter((timer) => timer.id !== id);
    };
    globalThis.__runTimers = (delay) => {
      const ready = globalThis.__testTimers.filter((timer) => timer.delay === delay);
      globalThis.__testTimers = globalThis.__testTimers.filter((timer) => timer.delay !== delay);
      for (const timer of ready) timer.callback();
    };
    $fetchSource
    globalThis.__fetchFor = (pluginId, generation, url, init = {}) => globalThis.fetch(url, init);
  ''');
  expect(setupResult.isError, isFalse, reason: setupResult.stringResult);
  await manager.loadPlugin(
    id: _manifest.id,
    manifest: _manifest,
    settings: {
      'Username': 'user',
      'Password': 'password',
      'LengthThreshold': 0,
      ...settings,
    },
    jsCode: _pluginSource,
  );
  addTearDown(() => manager.unloadPlugin(_manifest.id));
  return manager;
}

Future<Object?> _waitForJs(PluginManager manager, String expression) async {
  for (var i = 0; i < 500; i++) {
    manager.js.executePendingJob();
    final result = manager.js.evaluate('JSON.stringify(($expression) ?? null)');
    expect(result.isError, isFalse, reason: result.stringResult);
    final value = jsonDecode(result.stringResult);
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Timed out waiting for JavaScript expression: $expression');
}

Future<Map<String, dynamic>> _callApi(
  PluginManager manager,
  String endpoint,
  Map<String, dynamic> body,
) async {
  const requestId = 'request-1';
  final response = manager.registerPendingHttp(_manifest.id, requestId);
  manager.dispatchEvent(_manifest.id, 'httpRequest', {
    'requestId': requestId,
    'endpoint': endpoint,
    'method': 'POST',
    'headers': <String, String>{},
    'body': body,
  });
  return response.timeout(const Duration(seconds: 5));
}

void _startAutoUpload(PluginManager manager) {
  manager.dispatchEvent(_manifest.id, 'stateUpdate', {
    'state': {'state': 'espresso'},
  });
  manager.dispatchEvent(_manifest.id, 'stateUpdate', {
    'state': {'state': 'idle'},
  });
}

void _dispatchShotUpdate(
  PluginManager manager,
  Map<String, dynamic> shot,
  Map<String, dynamic> patch,
) {
  manager.dispatchEvent(_manifest.id, 'shotUpdated', {
    'id': shot['id'],
    'shot': shot,
    'patch': patch,
  });
}

void main() {
  test('upload encodes non-zero stage markers', () async {
    final shot = _shot();
    final manager = await _loadPlugin('''
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return { ok: true, json: async () => (${jsonEncode(shot)}) };
        }
        if (url.endsWith('/shots/upload')) {
          const start = init.body.indexOf('\\r\\n\\r\\n') + 4;
          const end = init.body.lastIndexOf('\\r\\n--');
          globalThis.__upload = JSON.parse(init.body.slice(start, end));
          return { ok: true, json: async () => ({ id: 'visualizer-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && init.method === 'PUT') {
          return { ok: true, json: async () => ({}) };
        }
        if (url.endsWith('/shots/visualizer-1?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-1', tags: [] }) };
        }
        if (url.endsWith('/shots/visualizer-1') && init.method === 'PATCH') {
          return { ok: true, json: async () => ({ id: 'visualizer-1', updated_at: 1 }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');

    _startAutoUpload(manager);
    final upload =
        await _waitForJs(manager, 'globalThis.__upload')
            as Map<String, dynamic>;

    expect(upload['state_change'], [1, 1, 2, 3]);
  });

  test('upload merges deduped local tags with current remote tags', () async {
    final shot = _shot(
      annotations: {
        'extras': {
          'tags': ['bright', 'floral'],
        },
      },
      context: {
        'extras': {
          'tags': ['fast shot', 'washed', 'bright'],
        },
      },
    );
    final manager = await _loadPlugin('''
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return { ok: true, json: async () => (${jsonEncode(shot)}) };
        }
        if (url.endsWith('/shots/upload')) {
          return { ok: true, json: async () => ({ id: 'visualizer-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && init.method === 'PUT') {
          return { ok: true, json: async () => ({}) };
        }
        if (url.endsWith('/shots/visualizer-1?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-1', tags: ['remote'] }) };
        }
        if (url.endsWith('/shots/visualizer-1') && init.method === 'PATCH') {
          globalThis.__patch = JSON.parse(init.body);
          return { ok: true, json: async () => ({ id: 'visualizer-1', updated_at: 1 }) };
        }
        throw new Error('Unexpected URL: ' + url + ' ' + (init.method || 'GET'));
      };
    ''');

    _startAutoUpload(manager);
    final patch =
        await _waitForJs(manager, 'globalThis.__patch') as Map<String, dynamic>;

    final shotPatch = patch['shot'] as Map<String, dynamic>;
    expect(shotPatch['tag_list'], [
      'fast shot',
      'washed',
      'bright',
      'floral',
      'remote',
    ]);
    expect(shotPatch.containsKey('tags'), isFalse);
  });

  test(
    'upload forwards an in-flight edit and does not suppress the next edit',
    () async {
      final initialShot = _shot();
      final duringUpload = _shot(
        annotations: {
          'extras': {
            'tags': ['during-upload'],
          },
        },
      );
      final afterMapping = _shot(
        annotations: {
          'extras': {
            'visualizerId': 'visualizer-1',
            'tags': ['after-mapping'],
          },
        },
      );
      final manager = await _loadPlugin('''
      globalThis.__currentShot = ${jsonEncode(initialShot)};
      globalThis.__remoteTags = [];
      globalThis.__patches = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return { ok: true, json: async () => globalThis.__currentShot };
        }
        if (url.endsWith('/shots/upload')) {
          globalThis.__uploadStarted = true;
          return await new Promise((resolve) => {
            globalThis.__finishUpload = () => resolve({
              ok: true,
              json: async () => ({ id: 'visualizer-1' }),
            });
          });
        }
        if (url.endsWith('/shots/shot-1') && init.method === 'PUT') {
          return { ok: true, json: async () => ({}) };
        }
        if (url.endsWith('/shots/visualizer-1?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-1', tags: globalThis.__remoteTags }) };
        }
        if (url.endsWith('/shots/visualizer-1') && init.method === 'PATCH') {
          const patch = JSON.parse(init.body);
          globalThis.__patches = [...globalThis.__patches, patch];
          globalThis.__remoteTags = patch.shot.tag_list;
          return { ok: true, json: async () => ({ id: 'visualizer-1', updated_at: globalThis.__patches.length }) };
        }
        throw new Error('Unexpected URL: ' + url + ' ' + (init.method || 'GET'));
      };
    ''');

      _startAutoUpload(manager);
      await _waitForJs(manager, 'globalThis.__uploadStarted');
      _dispatchShotUpdate(manager, duringUpload, {
        'annotations': {
          'extras': {
            'tags': ['during-upload'],
          },
        },
      });
      final finishUpload = manager.js.evaluate('''
      globalThis.__currentShot = ${jsonEncode(duringUpload)};
      globalThis.__finishUpload();
    ''');
      expect(finishUpload.isError, isFalse, reason: finishUpload.stringResult);
      final firstPatch =
          await _waitForJs(
                manager,
                'globalThis.__patches.length === 1 ? globalThis.__patches[0] : null',
              )
              as Map<String, dynamic>;
      expect((firstPatch['shot'] as Map<String, dynamic>)['tag_list'], [
        'during-upload',
      ]);

      _dispatchShotUpdate(manager, duringUpload, {
        'annotations': {
          'extras': {'visualizerId': 'visualizer-1'},
        },
      });
      _dispatchShotUpdate(manager, afterMapping, {
        'annotations': {
          'extras': {
            'tags': ['after-mapping'],
          },
        },
      });
      final secondPatch =
          await _waitForJs(
                manager,
                'globalThis.__patches.length === 2 ? globalThis.__patches[1] : null',
              )
              as Map<String, dynamic>;
      expect((secondPatch['shot'] as Map<String, dynamic>)['tag_list'], [
        'after-mapping',
      ]);
    },
  );

  test('post-upload refresh does not overwrite a newer tag edit', () async {
    final staleShot = _shot(
      annotations: {
        'extras': {
          'tags': ['stale'],
        },
      },
    );
    final latestShot = _shot(
      annotations: {
        'extras': {
          'visualizerId': 'visualizer-1',
          'tags': ['latest'],
        },
      },
    );
    final manager = await _loadPlugin('''
      globalThis.__shotReads = 0;
      globalThis.__patches = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          globalThis.__shotReads += 1;
          if (globalThis.__shotReads === 1) {
            return { ok: true, json: async () => (${jsonEncode(staleShot)}) };
          }
          globalThis.__refreshStarted = true;
          return await new Promise((resolve) => {
            globalThis.__finishRefresh = () => resolve({
              ok: true,
              json: async () => {
                globalThis.__refreshRead = true;
                return ${jsonEncode(staleShot)};
              },
            });
          });
        }
        if (url.endsWith('/shots/upload')) {
          return { ok: true, json: async () => ({ id: 'visualizer-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && init.method === 'PUT') {
          return { ok: true, json: async () => ({}) };
        }
        if (url.endsWith('/shots/visualizer-1?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-1', tags: [] }) };
        }
        if (url.endsWith('/shots/visualizer-1') && init.method === 'PATCH') {
          globalThis.__patches = [...globalThis.__patches, JSON.parse(init.body)];
          return { ok: true, json: async () => ({ id: 'visualizer-1', updated_at: globalThis.__patches.length }) };
        }
        throw new Error('Unexpected URL: ' + url + ' ' + (init.method || 'GET'));
      };
    ''');

    _startAutoUpload(manager);
    await _waitForJs(manager, 'globalThis.__refreshStarted');
    _dispatchShotUpdate(manager, latestShot, {
      'annotations': {
        'extras': {
          'tags': ['latest'],
        },
      },
    });
    await _waitForJs(
      manager,
      'globalThis.__patches.length === 1 ? true : null',
    );

    final finishRefresh = manager.js.evaluate('globalThis.__finishRefresh()');
    expect(finishRefresh.isError, isFalse, reason: finishRefresh.stringResult);
    await _waitForJs(manager, 'globalThis.__refreshRead');
    for (var i = 0; i < 20; i++) {
      manager.js.executePendingJob();
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final patches =
        await _waitForJs(manager, 'globalThis.__patches') as List<dynamic>;

    expect(patches, hasLength(1));
    expect(
      ((patches.single as Map<String, dynamic>)['shot']
          as Map<String, dynamic>)['tag_list'],
      ['latest'],
    );
  });

  test('forward sync preserves remote-only tags and removes local tags', () async {
    final manager = await _loadPlugin('''
      globalThis.__remoteTags = ['remote'];
      globalThis.__patches = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/visualizer-9?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-9', tags: globalThis.__remoteTags }) };
        }
        if (url.endsWith('/shots/visualizer-9') && init.method === 'PATCH') {
          const patch = JSON.parse(init.body);
          globalThis.__patches = [...globalThis.__patches, patch];
          globalThis.__remoteTags = patch.shot.tag_list;
          return { ok: true, json: async () => ({ id: 'visualizer-9', updated_at: globalThis.__patches.length }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'extras': {
            'visualizerId': 'visualizer-9',
            'tags': ['local'],
          },
        },
      ),
      {
        'annotations': {
          'extras': {
            'tags': ['local'],
          },
        },
      },
    );
    final firstPatch =
        await _waitForJs(
              manager,
              'globalThis.__patches.length === 1 ? globalThis.__patches[0] : null',
            )
            as Map<String, dynamic>;
    expect((firstPatch['shot'] as Map<String, dynamic>)['tag_list'], [
      'local',
      'remote',
    ]);

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'extras': {'visualizerId': 'visualizer-9'},
        },
      ),
      {
        'annotations': {
          'extras': {'tags': <String>[]},
        },
      },
    );
    final secondPatch =
        await _waitForJs(
              manager,
              'globalThis.__patches.length === 2 ? globalThis.__patches[1] : null',
            )
            as Map<String, dynamic>;
    expect((secondPatch['shot'] as Map<String, dynamic>)['tag_list'], [
      'remote',
    ]);
  });

  test('tag ownership follows Visualizer canonicalization', () async {
    final manager = await _loadPlugin('''
      globalThis.__remoteTags = [];
      globalThis.__patches = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/visualizer-9?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-9', tags: globalThis.__remoteTags }) };
        }
        if (url.endsWith('/shots/visualizer-9') && init.method === 'PATCH') {
          const patch = JSON.parse(init.body);
          globalThis.__patches = [...globalThis.__patches, patch];
          globalThis.__remoteTags = globalThis.__patches.length === 1
            ? ['high-speed']
            : patch.shot.tag_list;
          return { ok: true, json: async () => ({ id: 'visualizer-9', updated_at: globalThis.__patches.length }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'extras': {
            'visualizerId': 'visualizer-9',
            'tags': ['  High@-Speed  '],
          },
        },
      ),
      {
        'annotations': {
          'extras': {
            'tags': ['  High@-Speed  '],
          },
        },
      },
    );
    final firstPatch =
        await _waitForJs(
              manager,
              'globalThis.__patches.length === 1 ? globalThis.__patches[0] : null',
            )
            as Map<String, dynamic>;
    expect((firstPatch['shot'] as Map<String, dynamic>)['tag_list'], [
      'High@-Speed',
    ]);

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'extras': {'visualizerId': 'visualizer-9'},
        },
      ),
      {
        'annotations': {
          'extras': {'tags': <String>[]},
        },
      },
    );
    final secondPatch =
        await _waitForJs(
              manager,
              'globalThis.__patches.length === 2 ? globalThis.__patches[1] : null',
            )
            as Map<String, dynamic>;
    expect((secondPatch['shot'] as Map<String, dynamic>)['tag_list'], isEmpty);
  });

  test('tag ownership survives plugin restart', () async {
    final manager = await _loadPlugin('''
      globalThis.__remoteTags = [];
      globalThis.__patches = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/visualizer-9?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-9', tags: globalThis.__remoteTags }) };
        }
        if (url.endsWith('/shots/visualizer-9') && init.method === 'PATCH') {
          const patch = JSON.parse(init.body);
          globalThis.__patches = [...globalThis.__patches, patch];
          globalThis.__remoteTags = patch.shot.tag_list;
          return { ok: true, json: async () => ({ id: 'visualizer-9', updated_at: globalThis.__patches.length }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');
    final firstSync = manager.emitStream.firstWhere(
      (event) => event['event'] == 'shotForwardSynced',
    );

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'extras': {
            'visualizerId': 'visualizer-9',
            'tags': ['washed'],
          },
        },
      ),
      {
        'annotations': {
          'extras': {
            'tags': ['washed'],
          },
        },
      },
    );
    await firstSync.timeout(const Duration(seconds: 5));
    await manager.unloadPlugin(_manifest.id);
    final storedOwnership = await manager.kvStore.get(
      namespace: _manifest.id,
      key: 'managedLocalTags',
    );
    expect(jsonDecode(storedOwnership as String), {
      'visualizer-9': ['washed'],
    });

    await manager.loadPlugin(
      id: _manifest.id,
      manifest: _manifest,
      settings: const {
        'Username': 'user',
        'Password': 'password',
        'LengthThreshold': 0,
      },
      jsCode: _pluginSource,
    );
    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'extras': {'visualizerId': 'visualizer-9'},
        },
      ),
      {
        'annotations': {
          'extras': {'tags': <String>[]},
        },
      },
    );
    final removalPatch =
        await _waitForJs(
              manager,
              'globalThis.__patches.length === 2 ? globalThis.__patches[1] : null',
            )
            as Map<String, dynamic>;
    expect((removalPatch['shot'] as Map<String, dynamic>)['tag_list'], isEmpty);
  });

  test('legacy metadata and shotNotes patches use canonical shot values', () async {
    final manager = await _loadPlugin('''
      globalThis.__remoteTags = [];
      globalThis.__patches = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/visualizer-9?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-9', tags: globalThis.__remoteTags }) };
        }
        if (url.endsWith('/shots/visualizer-9') && init.method === 'PATCH') {
          const patch = JSON.parse(init.body);
          globalThis.__patches = [...globalThis.__patches, patch];
          if (patch.shot.tag_list) globalThis.__remoteTags = patch.shot.tag_list;
          return { ok: true, json: async () => ({ id: 'visualizer-9', updated_at: globalThis.__patches.length }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'extras': {
            'visualizerId': 'visualizer-9',
            'tags': ['washed'],
          },
        },
      ),
      {
        'metadata': {
          'tags': ['washed'],
        },
      },
    );
    final firstPatch =
        await _waitForJs(
              manager,
              'globalThis.__patches.length === 1 ? globalThis.__patches[0] : null',
            )
            as Map<String, dynamic>;
    expect((firstPatch['shot'] as Map<String, dynamic>)['tag_list'], [
      'washed',
    ]);

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'extras': {'visualizerId': 'visualizer-9'},
        },
      ),
      {'metadata': null},
    );
    final secondPatch =
        await _waitForJs(
              manager,
              'globalThis.__patches.length === 2 ? globalThis.__patches[1] : null',
            )
            as Map<String, dynamic>;
    expect((secondPatch['shot'] as Map<String, dynamic>)['tag_list'], isEmpty);

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'espressoNotes': 'legacy note',
          'extras': {'visualizerId': 'visualizer-9'},
        },
      ),
      {'shotNotes': 'legacy note'},
    );
    final thirdPatch =
        await _waitForJs(
              manager,
              'globalThis.__patches.length === 3 ? globalThis.__patches[2] : null',
            )
            as Map<String, dynamic>;
    expect(
      (thirdPatch['shot'] as Map<String, dynamic>)['espresso_notes'],
      'legacy note',
    );
  });

  test('forward sync leaves the global back-sync cursor unchanged', () async {
    final manager = await _loadPlugin(
      '''
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/visualizer-b') && init.method === 'PATCH') {
          globalThis.__forwardPatch = JSON.parse(init.body);
          return { ok: true, json: async () => ({ id: 'visualizer-b', updated_at: 120 }) };
        }
        if (url.endsWith('/me')) {
          return { ok: true, json: async () => ({ id: 'user-1' }) };
        }
        if (url.includes('/shots?sort=updated_at&items=50&page=1')) {
          globalThis.__changedUrl = url;
          return { ok: true, json: async () => ({ user_id: 'user-1', data: [{ id: 'visualizer-a', updated_at: 110 }] }) };
        }
        if (url.endsWith('/shots/visualizer-a?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-a', updated_at: 110, espresso_notes: 'remote edit' }) };
        }
        if (url.endsWith('/shots/local-a') && init.method === 'PUT') {
          globalThis.__localUpdate = JSON.parse(init.body);
          return { ok: true, json: async () => ({}) };
        }
        throw new Error('Unexpected URL: ' + url + ' ' + (init.method || 'GET'));
      };
    ''',
      settings: const {'BackSync': true},
    );
    manager.dispatchEvent(_manifest.id, 'storageRead', {
      'key': 'shotMap',
      'value': jsonEncode({
        'visualizer-a': 'local-a',
        'visualizer-b': 'shot-1',
      }),
    });
    manager.dispatchEvent(_manifest.id, 'storageRead', {
      'key': 'backSyncCursor',
      'value': '100',
    });

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'espressoNotes': 'local edit',
          'extras': {'visualizerId': 'visualizer-b'},
        },
      ),
      {
        'annotations': {'espressoNotes': 'local edit'},
      },
    );
    await _waitForJs(manager, 'globalThis.__forwardPatch');
    manager.js.evaluate('globalThis.__runTimers(30000)');
    final localUpdate =
        await _waitForJs(manager, 'globalThis.__localUpdate')
            as Map<String, dynamic>;
    final changedUrl =
        await _waitForJs(manager, 'globalThis.__changedUrl') as String;

    expect(changedUrl, contains('updated_after=100'));
    expect(localUpdate['annotations']['espressoNotes'], 'remote edit');
  });

  test('a stale success keeps ownership and drops completed fields', () async {
    final manager = await _loadPlugin('''
      globalThis.__patches = [];
      globalThis.__remoteTags = ['remote'];
      globalThis.fetch = (url, init = {}) => {
        if (url.endsWith('/shots/visualizer-9?essentials=1')) {
          return Promise.resolve({ ok: true, json: async () => ({ id: 'visualizer-9', tags: globalThis.__remoteTags }) });
        }
        if (url.endsWith('/shots/visualizer-9') && init.method === 'PATCH') {
          const patch = JSON.parse(init.body);
          globalThis.__patches = [...globalThis.__patches, patch];
          if (globalThis.__patches.length === 1) {
            return new Promise((resolve) => { globalThis.__firstResolver = resolve; });
          }
          return Promise.resolve({ ok: true, json: async () => ({ id: 'visualizer-9', updated_at: 2 }) });
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');

    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'espressoNotes': 'local notes',
          'extras': {
            'visualizerId': 'visualizer-9',
            'tags': ['old'],
          },
        },
      ),
      {
        'annotations': {
          'espressoNotes': 'local notes',
          'extras': {
            'tags': ['old'],
          },
        },
      },
    );
    await _waitForJs(manager, 'globalThis.__firstResolver ? true : null');
    _dispatchShotUpdate(
      manager,
      _shot(
        annotations: {
          'espressoNotes': 'local notes',
          'extras': {
            'visualizerId': 'visualizer-9',
            'tags': ['latest'],
          },
        },
      ),
      {
        'annotations': {
          'extras': {
            'tags': ['latest'],
          },
        },
      },
    );
    final resolve = manager.js.evaluate('''
      globalThis.__remoteTags = ['old', 'remote'];
      globalThis.__firstResolver({ ok: true, json: async () => ({ id: 'visualizer-9', updated_at: 1 }) });
    ''');
    expect(resolve.isError, isFalse, reason: resolve.stringResult);
    final patches =
        await _waitForJs(
              manager,
              'globalThis.__patches.length === 2 ? globalThis.__patches : null',
            )
            as List<dynamic>;
    final latest = (patches.last as Map<String, dynamic>)['shot'] as Map;

    expect(latest['tag_list'], ['latest', 'remote']);
    expect(latest.containsKey('espresso_notes'), isFalse);
  });

  test(
    'successful upload returns its id and surfaces the premium tag gate',
    () async {
      final shot = _shot(
        annotations: {
          'extras': {
            'tags': ['bright'],
          },
        },
      );
      final manager = await _loadPlugin('''
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return {
            ok: true,
            json: async () => (${jsonEncode(shot)}),
            text: async () => '${jsonEncode(shot)}',
          };
        }
        if (url.endsWith('/shots/upload')) {
          return { ok: true, json: async () => ({ id: 'visualizer-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && init.method === 'PUT') {
          return { ok: true, json: async () => ({}) };
        }
        if (url.endsWith('/shots/visualizer-1?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-1', tags: [] }) };
        }
        if (url.endsWith('/shots/visualizer-1') && init.method === 'PATCH') {
          globalThis.__tagPatch = JSON.parse(init.body);
          return await new Promise((resolve) => {
            globalThis.__failTagSync = () => resolve({
              ok: false,
              status: 400,
              statusText: 'Bad Request',
              text: async () => '{"error":"param is missing or the value is empty or invalid: shot"}',
            });
          });
        }
        throw new Error('Unexpected URL: ' + url + ' ' + (init.method || 'GET'));
      };
    ''');
      final errorEvent = manager.emitStream.firstWhere(
        (event) => event['event'] == 'shotForwardSyncError',
      );

      final response = await _callApi(manager, 'upload', {'shotId': 'shot-1'});
      final body =
          jsonDecode(response['body'] as String) as Map<String, dynamic>;

      expect(response['status'], 202);
      expect(body, {'visualizer_id': 'visualizer-1', 'tag_sync_pending': true});

      final tagPatch =
          await _waitForJs(manager, 'globalThis.__tagPatch')
              as Map<String, dynamic>;
      expect((tagPatch['shot'] as Map<String, dynamic>)['tag_list'], [
        'bright',
      ]);
      expect(
        (tagPatch['shot'] as Map<String, dynamic>).containsKey('tags'),
        isFalse,
      );
      final failTagSync = manager.js.evaluate('globalThis.__failTagSync()');
      expect(failTagSync.isError, isFalse, reason: failTagSync.stringResult);
      while (manager.js.executePendingJob() > 0) {}
      final event = await errorEvent.timeout(const Duration(seconds: 5));
      expect(event['payload']['error'], contains('Visualizer Premium'));
      expect(event['payload']['error'], contains('HTTP 400'));
    },
  );

  test('plugin source and manifest versions match', () {
    final sourceVersion = RegExp(
      r'version:\s*"([^"]+)"',
    ).firstMatch(_pluginSource)?.group(1);

    expect(sourceVersion, _manifest.version);
  });
}
