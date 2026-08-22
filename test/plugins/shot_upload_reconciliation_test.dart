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
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      values[key] = value;

  @override
  Future<void> delete({required String key}) async => values.remove(key);
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
  bool capturedMachine = true,
  String serialNumber = '6262',
  bool uploaded = false,
  bool rejected = false,
}) {
  final extras = <String, dynamic>{
    if (uploaded) 'uploaded_to_decent': 1,
    if (rejected) 'decent_upload_rejected': {'status': 422, 'timestamp': 1},
  };
  return {
    'id': id,
    'timestamp': '2026-01-01T00:00:00Z',
    'annotations': {'extras': extras},
    'workflow': {
      'profile': {'title': 'Test', 'steps': <dynamic>[]},
      'context': <String, dynamic>{},
      if (capturedMachine)
        'machine': {
          'serialNumber': serialNumber,
          'model': 'DE1Pro',
          'firmwareVersion': '1352',
        },
    },
    'measurements': [
      for (final timestamp in const [
        '2026-01-01T00:00:00Z',
        '2026-01-01T00:00:30Z',
      ])
        {
          'machine': {'timestamp': timestamp},
        },
    ],
  };
}

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

class _Harness {
  const _Harness(this.manager, this.requests);

  final PluginManager manager;
  final List<http.Request> requests;

  Future<bool> runNextTimer() async {
    final result = manager.js.evaluate('String(globalThis.__runNextTimer())');
    expect(result.isError, isFalse, reason: result.stringResult);
    await pump();
    return result.stringResult == 'true';
  }

  Future<void> pump() async {
    for (var i = 0; i < 50; i++) {
      while (manager.js.executePendingJob() > 0) {}
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<Map<String, dynamic>> putBodies() {
    final result = manager.js.evaluate('JSON.stringify(globalThis.__puts)');
    expect(result.isError, isFalse, reason: result.stringResult);
    return (jsonDecode(result.stringResult) as List)
        .cast<Map<String, dynamic>>()
        .map((put) => jsonDecode(put['body'] as String) as Map<String, dynamic>)
        .toList();
  }
}

Future<_Harness> _load({
  required List<Map<String, dynamic>> shots,
  required List<int> responseStatuses,
  String? machineState = 'sleeping',
  void Function(PluginManager manager)? onRequest,
}) async {
  final credentials = _FakeCredentialStore();
  await credentials.write(key: 'email', value: 'user@example.com');
  await credentials.write(key: 'password', value: 'password');
  final requests = <http.Request>[];
  final statuses = List<int>.from(responseStatuses);
  late final PluginManager manager;
  manager = PluginManager(
    kvStore: _FakeKeyValueStore(),
    decentProxyService: DecentProxyService(
      credentialStore: credentials,
      httpClient: http_testing.MockClient((request) async {
        requests.add(request);
        onRequest?.call(manager);
        final status = statuses.isEmpty ? 200 : statuses.removeAt(0);
        return http.Response(
          status >= 200 && status < 300
              ? jsonEncode({'ok': true, 'profile_ref': request.body.hashCode})
              : 'rejected',
          status,
        );
      }),
    ),
  );
  final fullShots = {for (final shot in shots) shot['id'] as String: shot};
  final setup = manager.js.evaluate('''
    globalThis.__shots = ${jsonEncode(shots)};
    globalThis.__fullShots = ${jsonEncode(fullShots)};
    globalThis.__machineState = ${jsonEncode(machineState)};
    globalThis.__puts = [];
    globalThis.__fetches = [];
    globalThis.__timers = [];
    globalThis.__nextTimerId = 0;
    globalThis.__timerSet = (pluginId, generation, callback, delay) => {
      const id = ++globalThis.__nextTimerId;
      globalThis.__timers.push({ id, callback, cancelled: false });
      return id;
    };
    globalThis.__timerClear = (pluginId, id) => {
      const timer = globalThis.__timers.find(item => item.id === id);
      if (timer) timer.cancelled = true;
    };
    globalThis.__runNextTimer = () => {
      while (globalThis.__timers.length > 0) {
        const timer = globalThis.__timers.shift();
        if (timer.cancelled) continue;
        timer.callback();
        return true;
      }
      return false;
    };
    globalThis.__fetchFor = async (pluginId, generation, url, init) => {
      const value = String(url);
      init = init || {};
      globalThis.__fetches.push(value);
      if (init.method === 'PUT') {
        globalThis.__puts.push({ url: value, body: init.body });
        const id = decodeURIComponent(value.substring(value.lastIndexOf('/') + 1));
        const patch = JSON.parse(init.body);
        const extras = patch.annotations && patch.annotations.extras;
        const merge = shot => {
          if (!shot || !extras) return;
          shot.annotations = shot.annotations || {};
          shot.annotations.extras = Object.assign({}, shot.annotations.extras || {}, extras);
        };
        merge(globalThis.__shots.find(shot => shot.id === id));
        merge(globalThis.__fullShots[id]);
        return { ok: true, status: 200, json: async () => ({}) };
      }
      if (value.endsWith('/machine/state')) {
        if (globalThis.__machineState === null) {
          return { ok: false, status: 503, json: async () => ({}) };
        }
        return { ok: true, status: 200, json: async () => ({ state: { state: globalThis.__machineState } }) };
      }
      if (value.indexOf('/shots?') >= 0) {
        const offsetMatch = value.match(/[?&]offset=([0-9]+)/);
        const limitMatch = value.match(/[?&]limit=([0-9]+)/);
        const offset = offsetMatch ? Number(offsetMatch[1]) : 0;
        const limit = limitMatch ? Number(limitMatch[1]) : 20;
        return {
          ok: true,
          status: 200,
          json: async () => ({
            items: globalThis.__shots.slice(offset, offset + limit),
            total: globalThis.__shots.length,
            limit,
            offset,
          }),
        };
      }
      if (value.indexOf('/shots/') >= 0) {
        const id = decodeURIComponent(value.substring(value.lastIndexOf('/') + 1));
        const shot = globalThis.__fullShots[id];
        return { ok: !!shot, status: shot ? 200 : 404, json: async () => shot };
      }
      if (value.endsWith('/info')) {
        return { ok: true, status: 200, json: async () => ({ version: '9.9.9' }) };
      }
      throw new Error('Unexpected URL: ' + value);
    };
  ''');
  expect(setup.isError, isFalse, reason: setup.stringResult);
  await manager.loadPlugin(
    id: _manifest().id,
    manifest: _manifest(),
    settings: {'AutoUpload': true, 'LengthThreshold': 0},
    jsCode: _pluginSource(),
  );
  final harness = _Harness(manager, requests);
  await harness.pump();
  return harness;
}

void main() {
  test(
    'reconciles only unmarked shots with captured machine identity',
    () async {
      final harness = await _load(
        shots: [
          _shot('eligible'),
          _shot('uploaded', uploaded: true),
          _shot('rejected', rejected: true),
          _shot('legacy', capturedMachine: false),
          _shot('simulated', serialNumber: 'MockDe1'),
        ],
        responseStatuses: [200],
      );

      expect(await harness.runNextTimer(), isTrue);
      await harness.pump();

      expect(harness.requests, hasLength(1));
      final payload =
          jsonDecode(harness.requests.single.body) as Map<String, dynamic>;
      expect(payload['id'], 'eligible');
      expect(payload['machine'], {
        'serialNumber': '6262',
        'model': 'DE1Pro',
        'firmwareVersion': '1352',
      });
      expect(
        harness.putBodies().single['annotations']['extras'],
        contains('uploaded_to_decent'),
      );
    },
  );

  test('resumes at the first unscanned shot after a bounded batch', () async {
    final harness = await _load(
      shots: [for (var i = 0; i < 21; i++) _shot('shot-$i')],
      responseStatuses: [],
    );

    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();
    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();

    expect(
      harness.requests.map(
        (request) => jsonDecode(request.body)['id'] as String,
      ),
      [for (var i = 0; i < 10; i++) 'shot-$i'],
    );
  });

  test('pauses reconciliation while the machine is active', () async {
    final harness = await _load(
      shots: [_shot('eligible')],
      responseStatuses: [200],
      machineState: 'espresso',
    );

    expect(await harness.runNextTimer(), isTrue);
    expect(harness.requests, isEmpty);

    harness.manager.js.evaluate("globalThis.__machineState = 'idle'");
    harness.manager.dispatchEvent(_manifest().id, 'stateUpdate', {
      'state': {'state': 'idle'},
    });
    await harness.pump();
    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();

    expect(harness.requests, hasLength(1));
  });

  test('does not reconcile when machine state is unavailable', () async {
    final harness = await _load(
      shots: [_shot('eligible')],
      responseStatuses: [200],
      machineState: null,
    );

    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();

    expect(harness.requests, isEmpty);
  });

  test('stops the backlog when automatic upload is disabled', () async {
    final harness = await _load(
      shots: [_shot('first'), _shot('second')],
      responseStatuses: [200, 200],
      onRequest: (manager) => manager.dispatchEvent(
        _manifest().id,
        'settingsUpdated',
        {'AutoUpload': false, 'LengthThreshold': 0},
      ),
    );

    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();

    expect(harness.requests, hasLength(1));
  });

  test('cancels retries when automatic upload is disabled', () async {
    final harness = await _load(
      shots: [_shot('eventual')],
      responseStatuses: [503, 200],
      onRequest: (manager) => manager.dispatchEvent(
        _manifest().id,
        'settingsUpdated',
        {'AutoUpload': false, 'LengthThreshold': 0},
      ),
    );

    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();
    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();

    expect(harness.requests, hasLength(1));
  });

  test('cancels retries when brewing starts', () async {
    final harness = await _load(
      shots: [_shot('eventual')],
      responseStatuses: [503, 200],
      onRequest: (manager) =>
          manager.dispatchEvent(_manifest().id, 'stateUpdate', {
            'state': {'state': 'espresso'},
          }),
    );

    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();
    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();

    expect(harness.requests, hasLength(1));
  });

  test('a rejected shot is marked and does not block the next shot', () async {
    final harness = await _load(
      shots: [_shot('bad'), _shot('good')],
      responseStatuses: [422, 200],
    );

    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();

    expect(harness.requests, hasLength(2));
    final extras = harness
        .putBodies()
        .map((body) => body['annotations']['extras'] as Map<String, dynamic>)
        .toList();
    expect(
      extras,
      contains(
        containsPair('decent_upload_rejected', containsPair('status', 422)),
      ),
    );
    expect(extras, contains(contains('uploaded_to_decent')));
  });

  test('transient failures resume on a later reconciliation pass', () async {
    final harness = await _load(
      shots: [_shot('eventual')],
      responseStatuses: [503, 503, 503, 200],
    );

    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();
    for (var i = 0; i < 3; i++) {
      expect(await harness.runNextTimer(), isTrue);
      await harness.pump();
    }

    expect(harness.requests, hasLength(4));
    expect(
      harness.putBodies().single['annotations']['extras'],
      contains('uploaded_to_decent'),
    );
  });

  test(
    'authorization failures are retried without rejecting the shot',
    () async {
      final harness = await _load(
        shots: [_shot('eventual')],
        responseStatuses: [403, 403, 403, 200],
      );

      expect(await harness.runNextTimer(), isTrue);
      await harness.pump();
      for (var i = 0; i < 3; i++) {
        expect(await harness.runNextTimer(), isTrue);
        await harness.pump();
      }

      expect(harness.requests, hasLength(4));
      final extras = harness.putBodies().single['annotations']['extras'];
      expect(extras, contains('uploaded_to_decent'));
      expect(extras['decent_upload_rejected'], isNull);
    },
  );
}
