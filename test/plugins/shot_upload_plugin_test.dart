import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';

class _FakeCredentialStore implements CredentialStore {
  final Map<String, String> _v = {};
  @override
  Future<String?> read({required String key}) async => _v[key];
  @override
  Future<void> write({required String key, required String value}) async =>
      _v[key] = value;
  @override
  Future<void> delete({required String key}) async => _v.remove(key);
}

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

Map<String, dynamic> _shot(
  String id, {
  String? capturedSerialNumber = 'captured-6262',
}) => {
  'id': id,
  'timestamp': '2026-01-01T00:00:00Z',
  'annotations': <String, dynamic>{},
  'workflow': {
    'profile': {'title': 'Damian LRv3', 'steps': <dynamic>[]},
    'context': <String, dynamic>{},
    if (capturedSerialNumber != null)
      'machine': {
        'serialNumber': capturedSerialNumber,
        'firmwareVersion': 'captured-1293',
        'model': 'captured-DE1Pro',
      },
  },
  'measurements': [
    for (final t in const ['2026-01-01T00:00:00Z', '2026-01-01T00:00:30Z'])
      {
        'machine': {
          'timestamp': t,
          'state': {'state': 'espresso', 'substate': 'pouring'},
          'pressure': 9,
          'flow': 2,
          'targetPressure': 9,
          'targetFlow': 2,
          'mixTemperature': 93,
          'groupTemperature': 92,
          'targetMixTemperature': 93,
          'targetGroupTemperature': 93,
          'profileFrame': 0,
          'steamTemperature': 0,
        },
        'scale': {'weight': 18, 'weightFlow': 2},
      },
  ],
};

// A row as the list endpoint returns it: no measurements, and the upload stamp
// carried in annotations.extras.
Map<String, dynamic> _historyRow(String id, {int? uploadedAt}) => {
  'id': id,
  'timestamp': '2026-01-01T00:00:00Z',
  'annotations': {
    if (uploadedAt != null) 'extras': {'uploaded_to_decent': uploadedAt},
  },
};

PluginManifest _manifest() => PluginManifest.fromJson(
  jsonDecode(
        File(
          'assets/plugins/shot-upload.reaplugin/manifest.json',
        ).readAsStringSync(),
      )
      as Map<String, dynamic>,
);

String _pluginSource() =>
    File('assets/plugins/shot-upload.reaplugin/plugin.js').readAsStringSync();

Future<void> _pumpUntil(
  PluginManager manager,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    while (manager.js.executePendingJob() > 0) {}
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  Future<PluginManager> load({
    required Map<String, dynamic> settings,
    required List<http.Request> captured,
    // Backlog-drain fixtures: the history the list endpoint serves, the machine
    // state the drain gates on, and an optional id the proxy should reject.
    List<Map<String, dynamic>> history = const [],
    String machineState = 'idle',
    int uploadStatus = 200,
    String serialNumber = '6262',
    String? capturedSerialNumber = 'captured-6262',
    bool manualTimers = false,
  }) async {
    final store = _FakeCredentialStore();
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');

    final manager = PluginManager(
      kvStore: _FakeKeyValueStore(),
      decentProxyService: DecentProxyService(
        credentialStore: store,
        httpClient: http_testing.MockClient((request) async {
          captured.add(request);
          return http.Response(
            jsonEncode(
              uploadStatus == 200
                  ? {'ok': true, 'profile_ref': 'damian@1'}
                  : {'ok': false, 'error': 'not your machine'},
            ),
            uploadStatus,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );
    final r = manager.js.evaluate('''
      globalThis.__timers = [];
      globalThis.__timerSet = (pluginId, generation, callback, delay) => {
        if (${manualTimers ? 'true' : 'false'}) {
          globalThis.__timers.push(callback);
          return globalThis.__timers.length;
        }
        callback();
        return 1;
      };
      globalThis.__timerClear = () => {};
      globalThis.__runTimers = () => {
        const callbacks = globalThis.__timers;
        globalThis.__timers = [];
        for (const callback of callbacks) callback();
      };
      globalThis.__puts = [];
      globalThis.__history = ${jsonEncode(history)};
      globalThis.__machineState = ${jsonEncode(machineState)};
      globalThis.__listCalls = 0;
      globalThis.__fetchFor = async (pluginId, generation, url, init) => {
        init = init || {};
        if (init.method === 'PUT') {
          globalThis.__puts.push({ url: String(url), body: init.body });
          // Writing the stamp is what stops a later pass re-uploading the shot.
          const id = String(url).split('/shots/')[1];
          const body = JSON.parse(init.body || '{}');
          const stamp = body.annotations && body.annotations.extras && body.annotations.extras.uploaded_to_decent;
          for (const s of globalThis.__history) {
            if (s.id === id && stamp) { s.annotations = s.annotations || {}; s.annotations.extras = { uploaded_to_decent: stamp }; }
          }
          return { ok:true, status:200, json: async () => ({}) };
        }
        if (url.indexOf('/shots?') >= 0) {
          globalThis.__listCalls++;
          const qs = String(url).split('?')[1] || '';
          const num = (k, d) => { const m = qs.match(new RegExp(k + '=(\\d+)')); return m ? parseInt(m[1], 10) : d; };
          const limit = num('limit', 20), offset = num('offset', 0);
          const all = globalThis.__history;
          return { ok:true, json: async () => ({ items: all.slice(offset, offset + limit), total: all.length, limit: limit, offset: offset }) };
        }
        if (url.endsWith('/machine/state')) return { ok:true, json: async () => ({ state: { state: globalThis.__machineState, substate: 'idle' } }) };
        if (url.endsWith('/shots/latest')) return { ok:true, json: async () => ({ id:'shot-1' }) };
        if (url.endsWith('/shots/shot-1')) return { ok:true, json: async () => (${jsonEncode(_shot('shot-1', capturedSerialNumber: capturedSerialNumber))}) };
        if (url.indexOf('/shots/') >= 0) {
          const id = String(url).split('/shots/')[1];
          const known = globalThis.__history.find(s => s.id === id);
          if (known) return { ok:true, json: async () => (${jsonEncode(_shot('ID', capturedSerialNumber: capturedSerialNumber)).replaceAll('"ID"', 'id')}) };
        }
        if (url.endsWith('/machine/info')) return { ok:true, json: async () => ({ serialNumber:${jsonEncode(serialNumber)}, version:'1293', model:'DE1Pro' }) };
        if (url.endsWith('/info')) return { ok:true, json: async () => ({ version:'9.9.9' }) };
        throw new Error('Unexpected URL: ' + url);
      };
    ''');
    expect(r.isError, isFalse, reason: r.stringResult);

    await manager.loadPlugin(
      id: _manifest().id,
      manifest: _manifest(),
      settings: settings,
      jsCode: _pluginSource(),
    );
    return manager;
  }

  test(
    'shotStored triggers an authenticated upload with correct provenance',
    () async {
      final captured = <http.Request>[];
      final manager = await load(
        settings: {'AutoUpload': true, 'LengthThreshold': 0},
        captured: captured,
      );

      final events = <Map<String, dynamic>>[];
      final sub = manager.emitStream.listen(events.add);
      manager.dispatchEvent(_manifest().id, 'shotStored', {'id': 'shot-1'});
      await _pumpUntil(
        manager,
        () => events.any((e) => e['event'] == 'shotUploaded'),
      );
      await sub.cancel();
      expect(
        events.any((e) => e['event'] == 'shotUploaded'),
        isTrue,
        reason: 'shotUploaded not emitted; events=$events',
      );

      expect(captured, hasLength(1));
      final req = captured.single;
      expect(req.method, 'POST');
      expect(
        req.url.toString(),
        'https://decentespresso.com/support/api/shot_upload',
      );
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['id'], 'shot-1');
      expect(body['machine']['serialNumber'], 'captured-6262');
      expect(body['machine']['firmwareVersion'], 'captured-1293');
      expect(body['machine'].containsKey('bleId'), isFalse);
      expect(body['app']['version'], '9.9.9');

      final puts =
          jsonDecode(
                manager.js
                    .evaluate('JSON.stringify(globalThis.__puts)')
                    .stringResult,
              )
              as List;
      expect(puts, hasLength(1));
      expect(puts.single['url'], endsWith('/api/v1/shots/shot-1'));
      final putBody =
          jsonDecode(puts.single['body'] as String) as Map<String, dynamic>;
      expect(
        putBody['annotations']['extras']['uploaded_to_decent'],
        isA<int>(),
      );
    },
  );

  test('does not upload when AutoUpload is off (opt-in default)', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: <String, dynamic>{},
      captured: captured,
    );
    manager.dispatchEvent(_manifest().id, 'shotStored', {'id': 'shot-1'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(captured, isEmpty);
  });

  test('storageRead-restored id is not re-uploaded (dedup)', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'AutoUpload': true, 'LengthThreshold': 0},
      captured: captured,
    );
    manager.dispatchEvent(_manifest().id, 'storageRead', {
      'key': 'lastUploadedShot',
      'value': 'shot-1',
    });
    manager.dispatchEvent(_manifest().id, 'shotStored', {'id': 'shot-1'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(captured, isEmpty);
  });

  // ---- backlog drain ----

  Future<void> runDrain(PluginManager manager) async {
    final done = manager.registerPendingHttp(_manifest().id, 'drain-1');
    manager.dispatchEvent(_manifest().id, 'httpRequest', {
      'requestId': 'drain-1',
      'endpoint': 'drain',
      'method': 'POST',
      'headers': <String, String>{},
      'body': null,
      'query': <String, String>{},
    });
    await done.timeout(const Duration(seconds: 5));
  }

  Future<Map<String, dynamic>> drainStatus(PluginManager manager) async {
    final done = manager.registerPendingHttp(_manifest().id, 'status-1');
    manager.dispatchEvent(_manifest().id, 'httpRequest', {
      'requestId': 'status-1',
      'endpoint': 'status',
      'method': 'GET',
      'headers': <String, String>{},
      'body': null,
      'query': <String, String>{},
    });
    final res = await done.timeout(const Duration(seconds: 5));
    return jsonDecode(res['body'] as String) as Map<String, dynamic>;
  }

  test('drain uploads only shots without an uploaded stamp', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'DrainHistory': true, 'LengthThreshold': 0},
      captured: captured,
      history: [
        _historyRow('old-1'),
        _historyRow('old-2', uploadedAt: 1787000000),
        _historyRow('old-3'),
      ],
    );
    await runDrain(manager);
    await _pumpUntil(manager, () => captured.length >= 2);

    expect(captured, hasLength(2), reason: 'the stamped shot must be skipped');
    final ids = captured
        .map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['id'])
        .toList();
    expect(ids, containsAll(<String>['old-1', 'old-3']));
    expect(ids, isNot(contains('old-2')));
  });

  test('drain uploads newest first', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'DrainHistory': true, 'LengthThreshold': 0},
      captured: captured,
      // the list endpoint serves newest-first
      history: [
        _historyRow('newest'),
        _historyRow('middle'),
        _historyRow('oldest'),
      ],
    );
    await runDrain(manager);
    await _pumpUntil(manager, () => captured.length >= 3);

    final ids = captured
        .map((r) => (jsonDecode(r.body) as Map<String, dynamic>)['id'])
        .toList();
    expect(ids, ['newest', 'middle', 'oldest']);
  });

  test('drain skips shots without captured machine identity', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'DrainHistory': true, 'LengthThreshold': 0},
      captured: captured,
      history: [_historyRow('ambiguous')],
      capturedSerialNumber: null,
    );
    await runDrain(manager);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    while (manager.js.executePendingJob() > 0) {}

    expect(captured, isEmpty);
  });

  test('disabling drain stops scheduled POST retries', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'DrainHistory': true, 'LengthThreshold': 0},
      captured: captured,
      history: [_historyRow('retry')],
      uploadStatus: 503,
      manualTimers: true,
    );
    await runDrain(manager);
    await _pumpUntil(manager, () => captured.isNotEmpty);

    manager.dispatchEvent(_manifest().id, 'settingsUpdated', {
      'DrainHistory': false,
      'LengthThreshold': 0,
    });
    manager.js.evaluate('globalThis.__runTimers()');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    while (manager.js.executePendingJob() > 0) {}

    expect(captured, hasLength(1));
  });

  test('brewing stops scheduled drain POST retries', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'DrainHistory': true, 'LengthThreshold': 0},
      captured: captured,
      history: [_historyRow('retry')],
      uploadStatus: 503,
      manualTimers: true,
    );
    await runDrain(manager);
    await _pumpUntil(manager, () => captured.isNotEmpty);

    manager.js.evaluate("globalThis.__machineState = 'espresso'");
    manager.js.evaluate('globalThis.__runTimers()');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    while (manager.js.executePendingJob() > 0) {}

    expect(captured, hasLength(1));
  });

  test('a second drain uploads nothing (the stamp is the ledger)', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'DrainHistory': true, 'LengthThreshold': 0},
      captured: captured,
      history: [_historyRow('a'), _historyRow('b')],
    );
    await runDrain(manager);
    await _pumpUntil(manager, () => captured.length >= 2);
    expect(captured, hasLength(2));

    captured.clear();
    await runDrain(manager);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    while (manager.js.executePendingJob() > 0) {}
    expect(captured, isEmpty, reason: 're-run must be a no-op');
  });

  test('drain does not run while the machine is busy', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'DrainHistory': true, 'LengthThreshold': 0},
      captured: captured,
      history: [_historyRow('a')],
      machineState: 'espresso',
    );
    await runDrain(manager);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    while (manager.js.executePendingJob() > 0) {}
    expect(captured, isEmpty);
  });

  test('a 4xx parks the shot instead of retrying it', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'DrainHistory': true, 'LengthThreshold': 0},
      captured: captured,
      history: [_historyRow('bad')],
      uploadStatus: 403,
    );
    await runDrain(manager);
    await _pumpUntil(manager, () => captured.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    while (manager.js.executePendingJob() > 0) {}

    expect(captured, hasLength(1), reason: '4xx must not be retried');
    final status = await drainStatus(manager);
    expect(status['drainParked'], 1);
  });

  test('drain does nothing while DrainHistory is off', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: <String, dynamic>{},
      captured: captured,
      history: [_historyRow('a')],
    );
    final done = manager.registerPendingHttp(_manifest().id, 'drain-off');
    manager.dispatchEvent(_manifest().id, 'httpRequest', {
      'requestId': 'drain-off',
      'endpoint': 'drain',
      'method': 'POST',
      'headers': <String, String>{},
      'body': null,
      'query': <String, String>{},
    });
    final res = await done.timeout(const Duration(seconds: 5));
    expect(res['status'], 409);
    expect(captured, isEmpty);
  });

  test('a shot pulled on a simulated machine is never uploaded', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'AutoUpload': true, 'LengthThreshold': 0},
      captured: captured,
      serialNumber: 'mock-de1',
      capturedSerialNumber: 'mock-de1',
    );
    manager.dispatchEvent(_manifest().id, 'shotStored', {'id': 'shot-1'});
    await _pumpUntil(manager, () {
      final puts =
          jsonDecode(
                manager.js
                    .evaluate('JSON.stringify(globalThis.__puts)')
                    .stringResult,
              )
              as List;
      return puts.isNotEmpty;
    });

    expect(captured, isEmpty, reason: 'a simulated shot must not be uploaded');
    // ... and it is marked so a later drain on the real machine cannot pick it up
    final puts =
        jsonDecode(
              manager.js
                  .evaluate('JSON.stringify(globalThis.__puts)')
                  .stringResult,
            )
            as List;
    final body =
        jsonDecode(puts.single['body'] as String) as Map<String, dynamic>;
    expect(body['annotations']['extras']['upload_skipped'], 'mock-device');
  });

  test(
    'drain does not upload a shot captured on a simulated machine',
    () async {
      final captured = <http.Request>[];
      final manager = await load(
        settings: {'DrainHistory': true, 'LengthThreshold': 0},
        captured: captured,
        history: [_historyRow('a'), _historyRow('b')],
        serialNumber: 'mock-de1',
        capturedSerialNumber: 'mock-de1',
      );
      await runDrain(manager);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      while (manager.js.executePendingJob() > 0) {}
      expect(captured, isEmpty);
    },
  );

  test('drain skips shots already marked upload_skipped', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'DrainHistory': true, 'LengthThreshold': 0},
      captured: captured,
      history: [
        {
          'id': 'mocky',
          'timestamp': '2026-01-01T00:00:00Z',
          'annotations': {
            'extras': {'upload_skipped': 'mock-device'},
          },
        },
        _historyRow('real'),
      ],
    );
    await runDrain(manager);
    await _pumpUntil(manager, () => captured.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    while (manager.js.executePendingJob() > 0) {}

    expect(captured, hasLength(1));
    expect(
      (jsonDecode(captured.single.body) as Map<String, dynamic>)['id'],
      'real',
    );
  });

  test('upload HTTP endpoint uploads the latest shot and reports ok', () async {
    final captured = <http.Request>[];
    final manager = await load(
      settings: {'AutoUpload': false, 'LengthThreshold': 0},
      captured: captured,
    );

    final responseFuture = manager.registerPendingHttp(_manifest().id, 'req-1');
    manager.dispatchEvent(_manifest().id, 'httpRequest', {
      'requestId': 'req-1',
      'endpoint': 'upload',
      'method': 'POST',
      'headers': <String, String>{},
      'body': null,
      'query': <String, String>{},
    });

    final response = await responseFuture.timeout(const Duration(seconds: 5));

    expect(captured, hasLength(1));
    expect(
      captured.single.url.toString(),
      'https://decentespresso.com/support/api/shot_upload',
    );
    expect(response['status'], 200);
    expect(jsonDecode(response['body'] as String)['ok'], true);
  });
}
