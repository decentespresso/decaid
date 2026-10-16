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
  FakeKeyValueStoreService? kvStore,
}) async {
  final manager = PluginManager(kvStore: kvStore ?? FakeKeyValueStoreService());
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

String _uploadFetchSource(
  Map<String, dynamic> shot, {
  String grinderHandler = '',
}) =>
    '''
      globalThis.__grinderFetched = false;
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return { ok: true, json: async () => (${jsonEncode(shot)}) };
        }
        $grinderHandler
        if (url.endsWith('/shots/upload')) {
          const start = init.body.indexOf('\\r\\n\\r\\n') + 4;
          const end = init.body.lastIndexOf('\\r\\n--');
          globalThis.__upload = JSON.parse(init.body.slice(start, end));
          return { ok: true, json: async () => ({ id: 'visualizer-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && init.method === 'PUT') {
          globalThis.__uploadStamp = JSON.parse(init.body);
          return { ok: true, json: async () => ({}) };
        }
        if (url.endsWith('/shots/visualizer-1?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-1', tags: [] }) };
        }
        if (url.endsWith('/shots/visualizer-1') && init.method === 'PATCH') {
          return { ok: true, json: async () => ({ id: 'visualizer-1', updated_at: 1 }) };
        }
        throw new Error('Unexpected URL: ' + url + ' ' + (init.method || 'GET'));
      };
    ''';

// Upload a shot and then let back-sync see Visualizer report
// [remoteGrinderModel] for it, so one test covers upload, edit and back-sync.
String _uploadThenBackSyncFetchSource(
  Map<String, dynamic> shot, {
  required String remoteGrinderModel,
}) =>
    '''
      globalThis.__grinderFetched = false;
      globalThis.__backSyncStarted = false;
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/me')) {
          globalThis.__backSyncStarted = true;
          return { ok: true, json: async () => ({ id: 'user-1' }) };
        }
        if (url.includes('/shots?sort=updated_at&items=50&page=1')) {
          return { ok: true, json: async () => ({ user_id: 'user-1', data: [{ id: 'visualizer-1', updated_at: 110 }] }) };
        }
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return { ok: true, json: async () => (${jsonEncode(shot)}) };
        }
        if (url.endsWith('/grinders/grinder-1')) {
          globalThis.__grinderFetched = true;
          return { ok: true, json: async () => ({ id: 'grinder-1', model: 'EG1', burrs: 'SSP HU' }) };
        }
        if (url.endsWith('/shots/upload')) {
          const start = init.body.indexOf('\\r\\n\\r\\n') + 4;
          const end = init.body.lastIndexOf('\\r\\n--');
          globalThis.__upload = JSON.parse(init.body.slice(start, end));
          return { ok: true, json: async () => ({ id: 'visualizer-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && init.method === 'PUT') {
          if (globalThis.__backSyncStarted) {
            globalThis.__backSyncUpdate = JSON.parse(init.body);
          } else {
            globalThis.__uploadStamp = JSON.parse(init.body);
          }
          return { ok: true, json: async () => ({}) };
        }
        if (url.endsWith('/shots/visualizer-1?essentials=1')) {
          return {
            ok: true,
            json: async () => ({
              id: 'visualizer-1',
              updated_at: 110,
              tags: [],
              grinder_model: ${jsonEncode(remoteGrinderModel)},
            }),
          };
        }
        if (url.endsWith('/shots/visualizer-1') && init.method === 'PATCH') {
          return { ok: true, json: async () => ({ id: 'visualizer-1', updated_at: 1 }) };
        }
        throw new Error('Unexpected URL: ' + url + ' ' + (init.method || 'GET'));
      };
    ''';

// A mapping restored from storage, so the plugin has no record of the exact
// string it uploaded and has to recompute it from the local shot.
String _backSyncFetchSource({required String remoteGrinderModel}) =>
    '''
      globalThis.__grinderFetched = false;
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/me')) {
          return { ok: true, json: async () => ({ id: 'user-1' }) };
        }
        if (url.includes('/shots?sort=updated_at&items=50&page=1')) {
          return { ok: true, json: async () => ({ user_id: 'user-1', data: [{ id: 'visualizer-c', updated_at: 110 }] }) };
        }
        if (url.endsWith('/shots/visualizer-c?essentials=1')) {
          return {
            ok: true,
            json: async () => ({
              id: 'visualizer-c',
              updated_at: 110,
              grinder_model: ${jsonEncode(remoteGrinderModel)},
            }),
          };
        }
        if (url.endsWith('/shots/local-c') && (!init.method || init.method === 'GET')) {
          return { ok: true, json: async () => ({ id: 'local-c', workflow: { context: { grinderId: 'grinder-1', grinderModel: 'EG1', grinderBurrs: 'Core' } } }) };
        }
        if (url.endsWith('/grinders/grinder-1')) {
          globalThis.__grinderFetched = true;
          return { ok: true, json: async () => ({ id: 'grinder-1', model: 'EG1', burrs: 'SSP HU' }) };
        }
        if (url.endsWith('/shots/local-c') && init.method === 'PUT') {
          globalThis.__backSyncUpdate = JSON.parse(init.body);
          return { ok: true, json: async () => ({}) };
        }
        throw new Error('Unexpected URL: ' + url + ' ' + (init.method || 'GET'));
      };
    ''';

void _primeBackSyncMapping(PluginManager manager) {
  manager.dispatchEvent(_manifest.id, 'storageRead', {
    'key': 'shotMap',
    'value': jsonEncode({'visualizer-c': 'local-c'}),
  });
  manager.dispatchEvent(_manifest.id, 'storageRead', {
    'key': 'backSyncCursor',
    'value': '100',
  });
}

Future<Object?> _uploadedGrinderModel(PluginManager manager) async {
  final upload =
      await _waitForJs(manager, 'globalThis.__upload') as Map<String, dynamic>;
  final settings = ((upload['app'] as Map)['data'] as Map)['settings'] as Map;
  return settings['grinder_model'];
}

bool _jsBool(PluginManager manager, String expression) {
  final result = manager.js.evaluate('JSON.stringify(($expression) ?? null)');
  expect(result.isError, isFalse, reason: result.stringResult);
  return jsonDecode(result.stringResult) == true;
}

// A mock whose local shot is mutated by the plugin's own PUTs, so one test can
// upload, take a remote edit through back-sync, and upload again.
String _roundTripFetchSource(Map<String, dynamic> shot) =>
    '''
      globalThis.__shot = ${jsonEncode(shot)};
      globalThis.__uploads = [];
      globalThis.__puts = [];
      globalThis.__remoteGrinderModel = 'EG1 (Core)';
      globalThis.__merge = (base, patch) => {
        for (const key of Object.keys(patch)) {
          const value = patch[key];
          if (value && typeof value === 'object' && !Array.isArray(value)) {
            const target = base[key] && typeof base[key] === 'object' ? base[key] : {};
            base[key] = globalThis.__merge(target, value);
          } else {
            base[key] = value;
          }
        }
        return base;
      };
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/me')) {
          return { ok: true, json: async () => ({ id: 'user-1' }) };
        }
        if (url.includes('/shots?limit=')) {
          return { ok: true, json: async () => ({ items: [globalThis.__shot], total: 1 }) };
        }
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return {
            ok: true,
            json: async () => globalThis.__shot,
            text: async () => JSON.stringify(globalThis.__shot),
          };
        }
        if (url.endsWith('/shots/upload')) {
          const start = init.body.indexOf('\\r\\n\\r\\n') + 4;
          const end = init.body.lastIndexOf('\\r\\n--');
          globalThis.__uploads = [...globalThis.__uploads, JSON.parse(init.body.slice(start, end))];
          return { ok: true, json: async () => ({ id: 'visualizer-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && init.method === 'PUT') {
          const patch = JSON.parse(init.body);
          globalThis.__puts = [...globalThis.__puts, patch];
          globalThis.__merge(globalThis.__shot, patch);
          return { ok: true, json: async () => ({}) };
        }
        if (url.endsWith('/shots/visualizer-1?essentials=1')) {
          return {
            ok: true,
            json: async () => ({
              id: 'visualizer-1',
              updated_at: 110,
              tags: [],
              grinder_model: globalThis.__remoteGrinderModel,
            }),
          };
        }
        if (url.endsWith('/shots/visualizer-1') && init.method === 'PATCH') {
          return { ok: true, json: async () => ({ id: 'visualizer-1', updated_at: 1 }) };
        }
        throw new Error('Unexpected URL: ' + url + ' ' + (init.method || 'GET'));
      };
    ''';

Map<String, dynamic> _snapshotShot() => _shot(
  context: {
    'grinderId': 'grinder-1',
    'grinderModel': 'EG1',
    'grinderBurrs': 'Core',
  },
);

String? _uploadedModelAt(Map<String, dynamic> upload) {
  final settings = ((upload['app'] as Map)['data'] as Map)['settings'] as Map;
  return settings['grinder_model'] as String?;
}

Map<String, dynamic> _lastContextPut(PluginManager manager) {
  final result = manager.js.evaluate('JSON.stringify(globalThis.__puts ?? [])');
  expect(result.isError, isFalse, reason: result.stringResult);
  final puts = (jsonDecode(result.stringResult) as List)
      .cast<Map<String, dynamic>>()
      .where((put) => put.containsKey('workflow'))
      .toList();
  expect(
    puts,
    isNotEmpty,
    reason: 'no back-sync update reached the local shot',
  );
  return (puts.last['workflow'] as Map)['context'] as Map<String, dynamic>;
}

void _setRemoteGrinderModel(PluginManager manager, String value) {
  final result = manager.js.evaluate(
    'globalThis.__remoteGrinderModel = ${jsonEncode(value)}',
  );
  expect(result.isError, isFalse, reason: result.stringResult);
}

void main() {
  test('uses a normalized custom server for uploads', () async {
    final shot = _shot();
    final manager = await _loadPlugin(
      '''
      globalThis.__uploadUrl = null;
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/latest')) {
          return { ok: true, json: async () => ({ id: 'shot-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return { ok: true, json: async () => (${jsonEncode(shot)}), text: async () => JSON.stringify(${jsonEncode(shot)}) };
        }
        if (url === 'https://mock.example/visualizer/api/shots/upload') {
          globalThis.__uploadUrl = url;
          return { ok: true, json: async () => ({ id: 'custom-1' }) };
        }
        if (url.endsWith('/shots/shot-1') && init.method === 'PUT') {
          return { ok: true, json: async () => ({}) };
        }
        if (url.endsWith('/shots/custom-1?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'custom-1', tags: [] }) };
        }
        if (url.endsWith('/shots/custom-1') && init.method === 'PATCH') {
          return { ok: true, json: async () => ({ id: 'custom-1', updated_at: 1 }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''',
      settings: {'ServerUrl': 'https://mock.example/visualizer///'},
    );

    _startAutoUpload(manager);
    expect(
      await _waitForJs(manager, 'globalThis.__uploadUrl'),
      'https://mock.example/visualizer/api/shots/upload',
    );

    final manual = await _callApi(manager, 'upload', {'shotId': 'shot-1'});
    expect(manual['status'], 202);
    expect(
      await _waitForJs(manager, 'globalThis.__uploadUrl'),
      'https://mock.example/visualizer/api/shots/upload',
    );
  });

  test(
    'rejects invalid server URL without falling back to hosted service',
    () async {
      final manager = await _loadPlugin(
        '''
      globalThis.fetch = async (url, init = {}) => {
        throw new Error('unexpected request: ' + url);
      };
    ''',
        settings: {'ServerUrl': 'https://mock.example/?token=secret'},
      );

      final status = await _callApi(manager, 'status', {});
      final body = jsonDecode(status['body'] as String) as Map<String, dynamic>;
      expect(body['serverUrl'], 'https://visualizer.coffee');
      expect(body['serverUrlError'], contains('query'));
    },
  );

  test('account validation uses the selected server', () async {
    final manager = await _loadPlugin(
      '''
      globalThis.__accountUrl = null;
      globalThis.fetch = async (url, init = {}) => {
        if (url === 'https://mock.example/visualizer/api/me') {
          globalThis.__accountUrl = url;
          return { ok: true, json: async () => ({ id: 'user-1' }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''',
      settings: {'ServerUrl': 'https://mock.example/visualizer'},
    );

    final result = await _callApi(manager, 'verifyCredentials', {
      'username': 'user',
      'password': 'password',
    });
    expect(jsonDecode(result['body'] as String)['valid'], isTrue);
    expect(
      await _waitForJs(manager, 'globalThis.__accountUrl'),
      'https://mock.example/visualizer/api/me',
    );
  });

  test(
    'preview credentials are explicit and do not change the selected server',
    () async {
      final manager = await _loadPlugin(
        '''
      globalThis.__previewRequests = [];
      globalThis.fetch = async (url, init = {}) => {
        globalThis.__previewRequests.push({url, auth: init.headers.Authorization});
        return {ok: true, status: 200};
      };
    ''',
        settings: {'ServerUrl': 'https://selected.example'},
      );
      final missing = await _callApi(manager, 'verifyCredentials', {
        'serverUrl': 'https://preview.example',
      });
      expect(missing['status'], 400);
      expect(
        _jsBool(manager, 'globalThis.__previewRequests.length === 0'),
        isTrue,
      );
      final preview = await _callApi(manager, 'verifyCredentials', {
        'serverUrl': 'https://preview.example/prefix/',
        'username': 'preview-user',
        'password': 'preview-password',
      });
      expect(jsonDecode(preview['body'] as String)['valid'], isTrue);
      expect(
        _jsBool(
          manager,
          'globalThis.__previewRequests[0].url === "https://preview.example/prefix/api/me" && globalThis.__previewRequests[0].auth === "Basic " + btoa("preview-user:preview-password")',
        ),
        isTrue,
      );
      final status = await _callApi(manager, 'status', {});
      expect(
        jsonDecode(status['body'] as String)['serverUrl'],
        'https://selected.example',
      );
    },
  );

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

  test(
    'upload folds the grinder burrs recorded on the shot into the model',
    () async {
      final shot = _shot(
        context: {
          'grinderId': 'grinder-1',
          'grinderModel': 'EG1',
          'grinderBurrs': 'Core',
        },
      );
      final manager = await _loadPlugin(_uploadFetchSource(shot));

      _startAutoUpload(manager);

      expect(await _uploadedGrinderModel(manager), 'EG1 (Core)');
    },
  );

  test(
    'upload does not add current grinder burrs to a shot without a snapshot',
    () async {
      final shot = _shot(
        context: {'grinderId': 'grinder-1', 'grinderModel': 'EG1'},
      );
      final manager = await _loadPlugin(
        _uploadFetchSource(
          shot,
          grinderHandler: '''
        if (url.endsWith('/grinders/grinder-1')) {
          globalThis.__grinderFetched = true;
          return { ok: true, json: async () => ({ id: 'grinder-1', model: 'EG1', burrs: 'SSP HU' }) };
        }
      ''',
        ),
      );

      _startAutoUpload(manager);

      expect(
        await _uploadedGrinderModel(manager),
        'EG1',
        reason:
            'a shot recorded before burrs were snapshotted must keep its own history',
      );
      expect(_jsBool(manager, 'globalThis.__grinderFetched'), isFalse);
    },
  );

  test(
    'upload keeps the burrs snapshot even after the grinder record changes',
    () async {
      final shot = _shot(
        context: {
          'grinderId': 'grinder-1',
          'grinderModel': 'EG1',
          'grinderBurrs': 'Core',
        },
      );
      final manager = await _loadPlugin(
        _uploadFetchSource(
          shot,
          grinderHandler: '''
        if (url.endsWith('/grinders/grinder-1')) {
          globalThis.__grinderFetched = true;
          return { ok: true, json: async () => ({ id: 'grinder-1', model: 'EG1 Renamed', burrs: 'SSP HU' }) };
        }
      ''',
        ),
      );

      _startAutoUpload(manager);

      expect(await _uploadedGrinderModel(manager), 'EG1 (Core)');
      expect(_jsBool(manager, 'globalThis.__grinderFetched'), isFalse);
    },
  );

  test(
    'upload does not duplicate burrs already present in the grinder model',
    () async {
      final shot = _shot(
        context: {
          'grinderId': 'grinder-2',
          'grinderModel': 'P64 (MP)',
          'grinderBurrs': 'MP',
        },
      );
      final manager = await _loadPlugin(_uploadFetchSource(shot));

      _startAutoUpload(manager);

      expect(await _uploadedGrinderModel(manager), 'P64 (MP)');
    },
  );

  test(
    'upload does not mistake a burr that is only a substring for one already named',
    () async {
      // A plain substring check treats "EK43" as already containing burr "4" (and
      // "Kinu M47" as already containing burr "M"), silently dropping the real burr.
      final shot = _shot(
        context: {
          'grinderId': 'grinder-3',
          'grinderModel': 'EK43',
          'grinderBurrs': '4',
        },
      );
      final manager = await _loadPlugin(_uploadFetchSource(shot));

      _startAutoUpload(manager);

      expect(await _uploadedGrinderModel(manager), 'EK43 (4)');
    },
  );

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
    final storedState = await manager.kvStore.get(
      namespace: _manifest.id,
      key: 'serverState',
    );
    final serverState =
        jsonDecode(storedState as String) as Map<String, dynamic>;
    expect(
      (serverState['https://visualizer.coffee'] as Map)['managedLocalTags'],
      {
        'visualizer-9': ['washed'],
      },
    );

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
              statusText: 'Authorization: Basic c2Vuc2l0aXZlLXNlY3JldA==',
              text: async () => '{"error":"Authorization: Basic c2Vuc2l0aXZlLXNlY3JldA=="}',
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
      expect(body, {
        'visualizer_id': 'visualizer-1',
        'serverUrl': 'https://visualizer.coffee',
        'shotUrl': 'https://visualizer.coffee/shots/visualizer-1',
        'tag_sync_pending': true,
      });

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
      expect(
        event['payload']['error'],
        isNot(contains('c2Vuc2l0aXZlLXNlY3JldA==')),
      );
    },
  );

  test('malformed remote JSON does not expose response text', () async {
    final manager = await _loadPlugin('''
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return { ok: true, json: async () => (${jsonEncode(_shot())}), text: async () => JSON.stringify(${jsonEncode(_shot())}) };
        }
        if (url.endsWith('/shots/upload')) {
          return { ok: true, json: async () => { throw new Error('malformed body echoed Authorization: Basic c2Vuc2l0aXZlLXNlY3JldA=='); } };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');
    final responseFuture = _callApi(manager, 'upload', {'shotId': 'shot-1'});
    for (var i = 0; i < 3; i++) {
      manager.js.evaluate('globalThis.__runTimers(2000)');
      while (manager.js.executePendingJob() > 0) {}
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final response = await responseFuture;
    expect(response['status'], 502);
    expect(response['body'], contains('invalid JSON response'));
    expect(response['body'], isNot(contains('c2Vuc2l0aXZlLXNlY3JldA==')));
    expect(response['body'], isNot(contains('malformed body echoed')));
  });

  test(
    'upload scales annotations.enjoyment to Visualizer espresso_enjoyment',
    () async {
      final shot = _shot(annotations: {'enjoyment': 8});
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

      expect(
        ((upload['app'] as Map)['data']
            as Map)['settings']['espresso_enjoyment'],
        '80',
      );
    },
  );

  test(
    'forward sync scales an enjoyment edit to Visualizer espresso_enjoyment',
    () async {
      final manager = await _loadPlugin('''
      globalThis.__patches = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/visualizer-9?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-9', tags: [] }) };
        }
        if (url.endsWith('/shots/visualizer-9') && init.method === 'PATCH') {
          const patch = JSON.parse(init.body);
          globalThis.__patches = [...globalThis.__patches, patch];
          return { ok: true, json: async () => ({ id: 'visualizer-9', updated_at: globalThis.__patches.length }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');

      _dispatchShotUpdate(
        manager,
        _shot(
          annotations: {
            'enjoyment': 8,
            'extras': {'visualizerId': 'visualizer-9'},
          },
        ),
        {
          'annotations': {'enjoyment': 8},
        },
      );
      final patch =
          await _waitForJs(
                manager,
                'globalThis.__patches.length === 1 ? globalThis.__patches[0] : null',
              )
              as Map<String, dynamic>;

      expect((patch['shot'] as Map<String, dynamic>)['espresso_enjoyment'], 80);
    },
  );

  test(
    'upload clamps an out-of-range enjoyment instead of multiplying it',
    () async {
      final shot = _shot(annotations: {'enjoyment': 80});
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

      expect(
        ((upload['app'] as Map)['data']
            as Map)['settings']['espresso_enjoyment'],
        '100',
      );
    },
  );

  test(
    'forward sync clamps an out-of-range enjoyment instead of multiplying it',
    () async {
      final manager = await _loadPlugin('''
      globalThis.__patches = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/visualizer-9?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-9', tags: [] }) };
        }
        if (url.endsWith('/shots/visualizer-9') && init.method === 'PATCH') {
          const patch = JSON.parse(init.body);
          globalThis.__patches = [...globalThis.__patches, patch];
          return { ok: true, json: async () => ({ id: 'visualizer-9', updated_at: globalThis.__patches.length }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');

      _dispatchShotUpdate(
        manager,
        _shot(
          annotations: {
            'enjoyment': 80,
            'extras': {'visualizerId': 'visualizer-9'},
          },
        ),
        {
          'annotations': {'enjoyment': 80},
        },
      );
      final patch =
          await _waitForJs(
                manager,
                'globalThis.__patches.length === 1 ? globalThis.__patches[0] : null',
              )
              as Map<String, dynamic>;

      expect(
        (patch['shot'] as Map<String, dynamic>)['espresso_enjoyment'],
        100,
      );
    },
  );

  test(
    'back sync scales Visualizer espresso_enjoyment to the annotations.enjoyment range',
    () async {
      final manager = await _loadPlugin(
        '''
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/me')) {
          return { ok: true, json: async () => ({ id: 'user-1' }) };
        }
        if (url.includes('/shots?sort=updated_at&items=50&page=1')) {
          return { ok: true, json: async () => ({ user_id: 'user-1', data: [{ id: 'visualizer-a', updated_at: 110 }] }) };
        }
        if (url.endsWith('/shots/visualizer-a?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-a', updated_at: 110, espresso_enjoyment: '80' }) };
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
        'value': jsonEncode({'visualizer-a': 'local-a'}),
      });
      manager.dispatchEvent(_manifest.id, 'storageRead', {
        'key': 'backSyncCursor',
        'value': '100',
      });
      manager.js.evaluate('globalThis.__runTimers(30000)');

      final localUpdate =
          await _waitForJs(manager, 'globalThis.__localUpdate')
              as Map<String, dynamic>;

      expect((localUpdate['annotations'] as Map)['enjoyment'], 8);
    },
  );

  test(
    'back sync clamps an out-of-range Visualizer enjoyment before local PUT',
    () async {
      final manager = await _loadPlugin(
        '''
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/me')) {
          return { ok: true, json: async () => ({ id: 'user-1' }) };
        }
        if (url.includes('/shots?sort=updated_at&items=50&page=1')) {
          return { ok: true, json: async () => ({ user_id: 'user-1', data: [{ id: 'visualizer-b', updated_at: 110 }] }) };
        }
        if (url.endsWith('/shots/visualizer-b?essentials=1')) {
          return { ok: true, json: async () => ({ id: 'visualizer-b', updated_at: 110, espresso_enjoyment: '120' }) };
        }
        if (url.endsWith('/shots/local-b') && init.method === 'PUT') {
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
        'value': jsonEncode({'visualizer-b': 'local-b'}),
      });
      manager.dispatchEvent(_manifest.id, 'storageRead', {
        'key': 'backSyncCursor',
        'value': '100',
      });
      manager.js.evaluate('globalThis.__runTimers(30000)');

      final localUpdate =
          await _waitForJs(manager, 'globalThis.__localUpdate')
              as Map<String, dynamic>;

      expect((localUpdate['annotations'] as Map)['enjoyment'], 10);
    },
  );

  test(
    'upload then back sync skips the grinder model we uploaded ourselves',
    () async {
      final shot = _shot(
        context: {
          'grinderId': 'grinder-1',
          'grinderModel': 'EG1',
          'grinderBurrs': 'Core',
        },
      );
      final manager = await _loadPlugin(
        _uploadThenBackSyncFetchSource(shot, remoteGrinderModel: 'EG1 (Core)'),
        settings: const {'BackSync': true},
      );
      manager.dispatchEvent(_manifest.id, 'storageRead', {
        'key': 'backSyncCursor',
        'value': '100',
      });

      _startAutoUpload(manager);
      await _waitForJs(manager, 'globalThis.__uploadStamp');
      manager.js.evaluate('globalThis.__runTimers(30000)');

      final update =
          await _waitForJs(manager, 'globalThis.__backSyncUpdate')
              as Map<String, dynamic>;
      final context = (update['workflow'] as Map?)?['context'] as Map?;

      expect(context?.containsKey('grinderModel') ?? false, isFalse);
    },
  );

  test(
    'upload then back sync applies a genuine Visualizer edit of the same shape',
    () async {
      final shot = _shot(
        context: {
          'grinderId': 'grinder-1',
          'grinderModel': 'EG1',
          'grinderBurrs': 'Core',
        },
      );
      final manager = await _loadPlugin(
        _uploadThenBackSyncFetchSource(
          shot,
          remoteGrinderModel: 'EG1 (Lab Sweet)',
        ),
        settings: const {'BackSync': true},
      );
      manager.dispatchEvent(_manifest.id, 'storageRead', {
        'key': 'backSyncCursor',
        'value': '100',
      });

      _startAutoUpload(manager);
      await _waitForJs(manager, 'globalThis.__uploadStamp');
      manager.js.evaluate('globalThis.__runTimers(30000)');

      final update =
          await _waitForJs(manager, 'globalThis.__backSyncUpdate')
              as Map<String, dynamic>;
      final context = (update['workflow'] as Map)['context'] as Map;

      expect(context['grinderModel'], 'EG1 (Lab Sweet)');
    },
  );

  test(
    'back sync skips an echo of a mapping uploaded before this session',
    () async {
      final manager = await _loadPlugin(
        _backSyncFetchSource(remoteGrinderModel: 'EG1 (Core)'),
        settings: const {'BackSync': true},
      );
      _primeBackSyncMapping(manager);
      manager.js.evaluate('globalThis.__runTimers(30000)');

      final update =
          await _waitForJs(manager, 'globalThis.__backSyncUpdate')
              as Map<String, dynamic>;
      final context = (update['workflow'] as Map?)?['context'] as Map?;

      expect(
        context?.containsKey('grinderModel') ?? false,
        isFalse,
        reason:
            'the value is recomputed from the shot\'s own recorded model and burrs',
      );
      expect(_jsBool(manager, 'globalThis.__grinderFetched'), isFalse);
    },
  );

  test(
    'back sync applies a remote edit for a mapping uploaded before this session',
    () async {
      final manager = await _loadPlugin(
        _backSyncFetchSource(remoteGrinderModel: 'EG1 (Lab Sweet)'),
        settings: const {'BackSync': true},
      );
      _primeBackSyncMapping(manager);
      manager.js.evaluate('globalThis.__runTimers(30000)');

      final update =
          await _waitForJs(manager, 'globalThis.__backSyncUpdate')
              as Map<String, dynamic>;
      final context = (update['workflow'] as Map)['context'] as Map;

      expect(context['grinderModel'], 'EG1 (Lab Sweet)');
      expect(_jsBool(manager, 'globalThis.__grinderFetched'), isFalse);
    },
  );

  test(
    'a back-synced model edit owns the field and is not re-decorated on re-upload',
    () async {
      final manager = await _loadPlugin(
        _roundTripFetchSource(_snapshotShot()),
        settings: const {'BackSync': true},
      );

      _startAutoUpload(manager);
      final first =
          await _waitForJs(manager, 'globalThis.__uploads[0]')
              as Map<String, dynamic>;
      expect(_uploadedModelAt(first), 'EG1 (Core)');

      _setRemoteGrinderModel(manager, 'EG1 (Lab Sweet)');
      await _callApi(manager, 'backSyncNow', const {});

      final context = _lastContextPut(manager);
      expect(context['grinderModel'], 'EG1 (Lab Sweet)');
      expect(
        context.containsKey('grinderBurrs'),
        isTrue,
        reason: 'the edited text owns the field, so the snapshot is cleared',
      );
      expect(context['grinderBurrs'], isNull);

      await _callApi(manager, 'upload', const {'shotId': 'shot-1'});
      final second =
          await _waitForJs(manager, 'globalThis.__uploads[1]')
              as Map<String, dynamic>;

      expect(
        _uploadedModelAt(second),
        'EG1 (Lab Sweet)',
        reason: 'the burrs must not be appended to the edited model again',
      );
    },
  );

  test(
    'back sync applies a remote revert to the value we originally uploaded',
    () async {
      final manager = await _loadPlugin(
        _roundTripFetchSource(_snapshotShot()),
        settings: const {'BackSync': true},
      );

      _startAutoUpload(manager);
      await _waitForJs(manager, 'globalThis.__uploads[0]');

      _setRemoteGrinderModel(manager, 'EG1 (Lab Sweet)');
      await _callApi(manager, 'backSyncNow', const {});
      expect(_lastContextPut(manager)['grinderModel'], 'EG1 (Lab Sweet)');

      _setRemoteGrinderModel(manager, 'EG1 (Core)');
      await _callApi(manager, 'backSyncNow', const {});

      expect(
        _lastContextPut(manager)['grinderModel'],
        'EG1 (Core)',
        reason:
            'reverting to our uploaded value is a genuine edit, not our own echo',
      );
    },
  );

  test(
    'an upload string recorded before the storage read survives it',
    () async {
      final manager = await _loadPlugin(
        _roundTripFetchSource(_snapshotShot()),
        settings: const {'BackSync': true},
      );

      _startAutoUpload(manager);
      await _waitForJs(manager, 'globalThis.__uploads[0]');

      final clearBurrs = manager.js.evaluate(
        'globalThis.__shot.workflow.context.grinderBurrs = null',
      );
      expect(clearBurrs.isError, isFalse, reason: clearBurrs.stringResult);
      manager.dispatchEvent(_manifest.id, 'storageRead', {
        'key': 'uploadedGrinderModels',
        'value': jsonEncode({'visualizer-9': 'Other (X)'}),
      });

      await _callApi(manager, 'backSyncNow', const {});

      expect(
        _lastContextPut(manager).containsKey('grinderModel'),
        isFalse,
        reason:
            'the echo is still recognised, so the late read must not drop the '
            'string this session recorded',
      );
    },
  );

  test('custom server is used for share-code and profile imports', () async {
    final manager = await _loadPlugin(
      '''
      globalThis.__importUrls = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url === 'https://mock.example/prefix/api/shots/shared?code=1234') {
          globalThis.__importUrls = [...globalThis.__importUrls, url];
          return { ok: true, json: async () => ([{ id: 'remote-1' }]) };
        }
        if (url === 'https://mock.example/prefix/api/shots/remote-1/profile?format=json') {
          globalThis.__importUrls = [...globalThis.__importUrls, url];
          return { ok: true, json: async () => ({ id: 'remote-1', title: 'Test profile' }) };
        }
        if (url.endsWith('/api/v1/profiles') && init.method === 'POST') {
          return { ok: true, json: async () => ({ id: 'local-profile' }) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''',
      settings: {'ServerUrl': 'https://mock.example/prefix'},
    );

    final response = await _callApi(manager, 'import', {'shareCode': '1234'});
    expect(response['status'], 200);
    expect(await _waitForJs(manager, 'globalThis.__importUrls.length'), 2);
    expect(
      _jsBool(
        manager,
        'globalThis.__importUrls.every((url) => url.startsWith("https://mock.example/prefix/api/"))',
      ),
      isTrue,
    );
  });

  test('custom server is used for authenticated back-sync', () async {
    final kvStore = FakeKeyValueStoreService();
    await kvStore.set(
      namespace: _manifest.id,
      key: 'serverState',
      value: jsonEncode({
        'https://mock.example/prefix': {
          'shotMap': {'remote-1': 'local-1'},
          'backSyncCursor': 100,
          'backSyncState': {},
          'uploadedGrinderModels': {},
          'managedLocalTags': {},
        },
      }),
    );
    final manager = await _loadPlugin(
      '''
      globalThis.__backSyncUrls = [];
      globalThis.fetch = async (url, init = {}) => {
        if (url === 'https://mock.example/prefix/api/me') {
          globalThis.__backSyncUrls = [...globalThis.__backSyncUrls, url];
          return { ok: true, json: async () => ({ id: 'user-1' }) };
        }
        if (url.startsWith('https://mock.example/prefix/api/shots?sort=updated_at')) {
          globalThis.__backSyncUrls = [...globalThis.__backSyncUrls, url];
          return { ok: true, json: async () => ({ user_id: 'user-1', data: [{ id: 'remote-1', updated_at: 110 }] }) };
        }
        if (url === 'https://mock.example/prefix/api/shots/remote-1?essentials=1') {
          globalThis.__backSyncUrls = [...globalThis.__backSyncUrls, url];
          return { ok: true, json: async () => ({ id: 'remote-1', updated_at: 110, espresso_enjoyment: '80' }) };
        }
        if (url.includes('/api/v1/shots?')) {
          return { ok: true, json: async () => ({ items: [{
            id: 'local-1', annotations: { extras: {
              visualizerId: 'remote-1', visualizerServerUrl: 'https://mock.example/prefix',
            } },
          }], total: 1 }) };
        }
        if (url.endsWith('/api/v1/shots/local-1') && init.method === 'GET') {
          return {
            ok: true,
            json: async () => ({
              id: 'local-1',
              annotations: { extras: {
                visualizerId: 'remote-1',
                visualizerServerUrl: 'https://mock.example/prefix',
              } },
            }),
          };
        }
        if (url.endsWith('/api/v1/shots/local-1') && init.method === 'PUT') {
          globalThis.__localBackSync = JSON.parse(init.body);
          return { ok: true, json: async () => ({}) };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''',
      settings: {'ServerUrl': 'https://mock.example/prefix', 'BackSync': true},
      kvStore: kvStore,
    );
    await _callApi(manager, 'backSyncNow', const {});

    expect(await _waitForJs(manager, 'globalThis.__localBackSync'), isNotNull);
    expect(
      _jsBool(
        manager,
        'globalThis.__backSyncUrls.every((url) => url.startsWith("https://mock.example/prefix/api/"))',
      ),
      isTrue,
    );
  });

  test('TLS errors are surfaced without exposing credentials', () async {
    final manager = await _loadPlugin(
      '''
      globalThis.fetch = async (url, init = {}) => {
        throw new Error('CERTIFICATE_VERIFY_FAILED');
      };
    ''',
      settings: {'ServerUrl': 'https://tls.example'},
    );

    final response = await _callApi(manager, 'verifyCredentials', {
      'username': 'user',
      'password': 'secret-value',
    });
    expect(jsonDecode(response['body'] as String)['valid'], isFalse);
    expect(response['body'], isNot(contains('secret-value')));
  });

  test(
    'credential verification never returns a candidate secret from a remote error',
    () async {
      final manager = await _loadPlugin(
        '''
      globalThis.fetch = async () => {
        throw new Error('transport echoed candidate-password Basic Y2FuZGlkYXRlLXVzZXI6Y2FuZGlkYXRlLXBhc3N3b3Jk');
      };
    ''',
        settings: {'ServerUrl': 'https://verify.example'},
      );

      final response = await _callApi(manager, 'verifyCredentials', {
        'username': 'candidate-user',
        'password': 'candidate-password',
      });
      expect(response['body'], isNot(contains('candidate-password')));
      expect(
        response['body'],
        isNot(contains('Y2FuZGlkYXRlLXVzZXI6Y2FuZGlkYXRlLXBhc3N3b3Jk')),
      );
    },
  );

  test('upload errors do not expose an untrusted response body', () async {
    final manager = await _loadPlugin('''
      globalThis.__uploadAttempts = 0;
      globalThis.fetch = async (url, init = {}) => {
        if (url.endsWith('/shots/shot-1') && (!init.method || init.method === 'GET')) {
          return { ok: true, json: async () => (${jsonEncode(_shot())}), text: async () => JSON.stringify(${jsonEncode(_shot())}) };
        }
        if (url.endsWith('/shots/upload')) {
          globalThis.__uploadAttempts += 1;
          return { ok: false, status: 500, text: async () => 'remote echoed shot-secret' };
        }
        throw new Error('Unexpected URL: ' + url);
      };
    ''');

    final responseFuture = _callApi(manager, 'upload', {'shotId': 'shot-1'});
    for (var i = 0; i < 3; i++) {
      manager.js.evaluate('globalThis.__runTimers(2000)');
      while (manager.js.executePendingJob() > 0) {}
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final response = await responseFuture;
    expect(response['status'], 502);
    expect(
      await _waitForJs(manager, 'globalThis.__uploadAttempts'),
      greaterThan(0),
    );
    expect(response['body'], isNot(contains('remote echoed shot-secret')));
  });

  test('scopes persisted upload mappings by server across A-B-A reloads', () async {
    final kvStore = FakeKeyValueStoreService();
    final shot = _shot();
    final managerA = await _loadPlugin(
      _uploadFetchSource(shot),
      settings: {'ServerUrl': 'https://server-a.example'},
      kvStore: kvStore,
    );
    _startAutoUpload(managerA);
    await _waitForJs(managerA, 'globalThis.__uploadStamp');
    await managerA.unloadPlugin(_manifest.id);

    final persistedAfterA =
        jsonDecode(
              await kvStore.get(namespace: _manifest.id, key: 'serverState')
                  as String,
            )
            as Map<String, dynamic>;
    expect(persistedAfterA['https://server-a.example'], isNotNull);

    final managerB = await _loadPlugin(
      'globalThis.fetch = async () => { throw new Error("unexpected B request"); };',
      settings: {'ServerUrl': 'https://server-b.example'},
      kvStore: kvStore,
    );
    await managerB.unloadPlugin(_manifest.id);

    final managerAAgain = await _loadPlugin(
      'globalThis.fetch = async () => { throw new Error("unexpected A request"); };',
      settings: {'ServerUrl': 'https://server-a.example'},
      kvStore: kvStore,
    );
    final response = await _callApi(managerAAgain, 'lastUpload', {});
    final body = jsonDecode(response['body'] as String) as Map<String, dynamic>;
    expect(body['visId'], 'visualizer-1');
    expect(body['serverUrl'], 'https://server-a.example');
  });

  test('plugin source and manifest versions match', () {
    final sourceVersion = RegExp(
      r'version:\s*"([^"]+)"',
    ).firstMatch(_pluginSource)?.group(1);

    expect(sourceVersion, _manifest.version);
  });
}
