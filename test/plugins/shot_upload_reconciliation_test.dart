import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/account/account_consent_gate.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
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
  String provenanceStatus = 'captured',
  bool uploaded = false,
  bool rejected = false,
  bool mockDeviceSkipped = false,
}) {
  final extras = <String, dynamic>{
    if (uploaded) 'uploaded_to_decent': 1,
    if (rejected) 'decent_upload_rejected': {'status': 422, 'timestamp': 1},
    if (mockDeviceSkipped) 'upload_skipped': 'mock-device',
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
          'provenanceStatus': provenanceStatus,
          if (serialNumber.isNotEmpty) ...{
            'serialNumber': serialNumber,
            'model': 'DE1Pro',
            'firmwareVersion': '1352',
          },
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

  Future<bool> runNextTimer({bool pumpJobs = true}) async {
    final result = manager.js.evaluate('String(globalThis.__runNextTimer())');
    expect(result.isError, isFalse, reason: result.stringResult);
    if (pumpJobs) await pump();
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

  List<String> fetches() {
    final result = manager.js.evaluate('JSON.stringify(globalThis.__fetches)');
    expect(result.isError, isFalse, reason: result.stringResult);
    return (jsonDecode(result.stringResult) as List).cast<String>();
  }
}

Future<bool> _allowConsent(String _) async => true;

Future<_Harness> _load({
  required List<Map<String, dynamic>> shots,
  required List<int> responseStatuses,
  String? machineState = 'sleeping',
  Map<String, dynamic>? connectedMachine = const {
    'serialNumber': '9999',
    'model': 'DE1XL',
    'version': '1400',
  },
  void Function(PluginManager manager)? onRequest,
  RequireAccountConsent requireConsent = _allowConsent,
  int annotationStatus = 200,
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
      requireConsent: requireConsent,
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
    globalThis.__connectedMachine = ${jsonEncode(connectedMachine)};
    globalThis.__puts = [];
    globalThis.__annotationStatus = $annotationStatus;
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
        if (globalThis.__annotationStatus < 200 || globalThis.__annotationStatus >= 300) {
          return { ok: false, status: globalThis.__annotationStatus, json: async () => ({}) };
        }
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
        const ordered = value.indexOf('order=desc') >= 0
          ? [...globalThis.__shots].reverse()
          : globalThis.__shots;
        return {
          ok: true,
          status: 200,
          json: async () => ({
            items: ordered.slice(offset, offset + limit),
            total: globalThis.__shots.length,
            limit,
            offset,
          }),
        };
      }
      if (value.endsWith('/shots/latest')) {
        const shot = globalThis.__shots[globalThis.__shots.length - 1];
        return { ok: !!shot, status: shot ? 200 : 404, json: async () => shot };
      }
      if (value.indexOf('/shots/') >= 0) {
        const id = decodeURIComponent(value.substring(value.lastIndexOf('/') + 1));
        const shot = globalThis.__fullShots[id];
        return { ok: !!shot, status: shot ? 200 : 404, json: async () => shot };
      }
      if (value.endsWith('/machine/info')) {
        const machine = globalThis.__connectedMachine;
        return { ok: machine !== null, status: machine === null ? 503 : 200, json: async () => machine };
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

  test(
    'uses the connected machine only when captured identity is absent',
    () async {
      final harness = await _load(
        shots: [
          _shot('legacy', capturedMachine: false),
          _shot('captured'),
          _shot('captured-mock', serialNumber: 'MockDe1'),
        ],
        responseStatuses: [200, 200],
      );

      expect(await harness.runNextTimer(), isTrue);
      await harness.pump();

      final payloads = {
        for (final request in harness.requests)
          jsonDecode(request.body)['id'] as String:
              jsonDecode(request.body) as Map<String, dynamic>,
      };
      expect(payloads.keys, {'captured', 'legacy'});
      expect(payloads['captured']!['machine']['serialNumber'], '6262');
      expect(payloads['legacy']!['machine'], {
        'serialNumber': '9999',
        'firmwareVersion': '1400',
        'model': 'DE1XL',
      });
      expect(
        harness.fetches().where((url) => url.endsWith('/machine/info')),
        hasLength(1),
      );
    },
  );

  test('legacy mock-device shots stay skipped with a real machine', () async {
    final harness = await _load(
      shots: [
        _shot('legacy-mock', capturedMachine: false, mockDeviceSkipped: true),
      ],
      responseStatuses: [200],
    );

    expect(await harness.runNextTimer(), isTrue);

    expect(harness.requests, isEmpty);
    expect(
      harness.fetches().where((url) => url.endsWith('/machine/info')),
      isEmpty,
    );
  });

  test(
    'failed capture never uses the connected machine automatically',
    () async {
      final harness = await _load(
        shots: [
          _shot(
            'capture-failed',
            serialNumber: '',
            provenanceStatus: 'unavailable',
          ),
        ],
        responseStatuses: [200],
        connectedMachine: const {
          'serialNumber': 'machine-b',
          'model': 'DE1XL',
          'version': '1400',
        },
      );

      expect(await harness.runNextTimer(), isTrue);

      expect(harness.requests, isEmpty);
      expect(
        harness.fetches().where((url) => url.endsWith('/machine/info')),
        isEmpty,
      );
    },
  );

  test('manual upload may override unavailable capture provenance', () async {
    final harness = await _load(
      shots: [
        _shot(
          'capture-failed',
          serialNumber: '',
          provenanceStatus: 'unavailable',
        ),
      ],
      responseStatuses: [200],
      connectedMachine: const {
        'serialNumber': 'machine-b',
        'model': 'DE1XL',
        'version': '1400',
      },
    );

    final responseFuture = harness.manager.registerPendingHttp(
      _manifest().id,
      'manual-upload',
    );
    harness.manager.dispatchEvent(_manifest().id, 'httpRequest', {
      'requestId': 'manual-upload',
      'endpoint': 'upload',
      'method': 'POST',
      'headers': <String, String>{},
      'body': null,
      'query': <String, String>{},
    });
    final response = await responseFuture;

    expect(response['status'], 200);
    expect(harness.requests, hasLength(1));
    expect(
      jsonDecode(harness.requests.single.body)['machine']['serialNumber'],
      'machine-b',
    );
  });

  for (final connectedMachine in <Map<String, dynamic>?>[
    null,
    {'serialNumber': 'MockDe1', 'version': '1400'},
  ]) {
    test(
      connectedMachine == null
          ? 'legacy fallback skips when no machine is connected'
          : 'legacy fallback skips a connected simulated machine',
      () async {
        final harness = await _load(
          shots: [_shot('legacy', capturedMachine: false)],
          responseStatuses: [200],
          connectedMachine: connectedMachine,
        );

        expect(await harness.runNextTimer(), isTrue);
        await harness.pump();

        expect(harness.requests, isEmpty);
      },
    );
  }

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
      [for (var i = 20; i > 10; i--) 'shot-$i'],
    );
    expect(
      harness.fetches().where((url) => url.contains('/shots?')),
      everyElement(contains('order=desc')),
    );
  });

  test('a live shot preempts the remaining reconciliation backlog', () async {
    var dispatched = false;
    late final _Harness harness;
    harness = await _load(
      shots: [_shot('live'), for (var i = 0; i < 10; i++) _shot('backlog-$i')],
      responseStatuses: [200, 200],
      onRequest: (manager) {
        if (dispatched) return;
        dispatched = true;
        manager.dispatchEvent(_manifest().id, 'shotStored', {'id': 'live'});
      },
    );

    expect(await harness.runNextTimer(), isTrue);
    await harness.pump();

    expect(
      harness.requests
          .map((request) => jsonDecode(request.body)['id'] as String)
          .take(2),
      ['backlog-9', 'live'],
    );
  });

  for (final decision in <AccountConsentDecision?>[
    AccountConsentDecision.denied,
    null,
  ]) {
    test(
      decision == null
          ? 'consent timeout pauses reconciliation without another prompt'
          : 'explicit consent denial pauses reconciliation without another prompt',
      () async {
        final consentStore = _FakeCredentialStore();
        var prompts = 0;
        final gate = AccountConsentGate(
          store: AccountConsentStore(credentialStore: consentStore),
          prompt: (_) async {
            prompts++;
            return decision;
          },
        );
        final harness = await _load(
          shots: [_shot('eligible')],
          responseStatuses: [200],
          requireConsent: gate.requireConsent,
        );

        expect(await harness.runNextTimer(), isTrue);
        await harness.pump();

        expect(harness.requests, isEmpty);
        expect(prompts, 1);
        expect(await harness.runNextTimer(), isFalse);
        harness.manager.dispatchEvent(_manifest().id, 'stateUpdate', {
          'state': {'state': 'espresso'},
        });
        harness.manager.dispatchEvent(_manifest().id, 'stateUpdate', {
          'state': {'state': 'idle'},
        });
        await harness.pump();
        expect(await harness.runNextTimer(), isFalse);
        expect(prompts, 1);
      },
    );
  }

  test('a queued live consent timeout stops the active pass', () async {
    final consentStore = _FakeCredentialStore();
    var prompts = 0;
    final gate = AccountConsentGate(
      store: AccountConsentStore(credentialStore: consentStore),
      prompt: (_) async {
        prompts++;
        return null;
      },
    );
    final harness = await _load(
      shots: [_shot('backlog'), _shot('live')],
      responseStatuses: [200],
      requireConsent: gate.requireConsent,
    );

    expect(await harness.runNextTimer(pumpJobs: false), isTrue);
    harness.manager.dispatchEvent(_manifest().id, 'shotStored', {'id': 'live'});
    await harness.pump();

    expect(prompts, 1);
    expect(harness.requests, isEmpty);
  });

  test(
    '0.2.1 reconciliation follows AutoUpload, not old DrainHistory',
    () async {
      final enabled = await _load(
        shots: [_shot('enabled')],
        responseStatuses: [200],
      );
      enabled.manager.dispatchEvent(_manifest().id, 'settingsUpdated', {
        'AutoUpload': true,
        'DrainHistory': false,
        'LengthThreshold': 0,
      });
      expect(await enabled.runNextTimer(), isTrue);
      await enabled.pump();
      expect(enabled.requests, hasLength(1));

      final disabled = await _load(
        shots: [_shot('disabled')],
        responseStatuses: [200],
      );
      disabled.manager.dispatchEvent(_manifest().id, 'settingsUpdated', {
        'AutoUpload': false,
        'DrainHistory': true,
        'LengthThreshold': 0,
      });
      await disabled.pump();
      expect(await disabled.runNextTimer(), isFalse);
      expect(disabled.requests, isEmpty);
    },
  );

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

  test(
    'failed rejection marking does not retry or block following shots',
    () async {
      final harness = await _load(
        shots: [_shot('good'), _shot('bad')],
        responseStatuses: [422, 200],
        annotationStatus: 500,
      );

      expect(await harness.runNextTimer(), isTrue);
      expect(await harness.runNextTimer(), isTrue);

      expect(
        harness.requests.map(
          (request) => jsonDecode(request.body)['id'] as String,
        ),
        ['bad', 'good'],
      );
    },
  );

  test('a new session may retry an undurably marked rejection once', () async {
    final shot = _shot('bad');
    final firstSession = await _load(
      shots: [shot],
      responseStatuses: [422],
      annotationStatus: 500,
    );
    expect(await firstSession.runNextTimer(), isTrue);
    expect(await firstSession.runNextTimer(), isTrue);
    expect(firstSession.requests, hasLength(1));

    final secondSession = await _load(
      shots: [shot],
      responseStatuses: [422],
      annotationStatus: 500,
    );
    expect(await secondSession.runNextTimer(), isTrue);
    expect(await secondSession.runNextTimer(), isTrue);
    expect(secondSession.requests, hasLength(1));
  });

  test('manual upload may retry a session-rejected shot', () async {
    final harness = await _load(
      shots: [_shot('bad')],
      responseStatuses: [422, 200],
      annotationStatus: 500,
    );
    expect(await harness.runNextTimer(), isTrue);
    expect(harness.requests, hasLength(1));

    final responseFuture = harness.manager.registerPendingHttp(
      _manifest().id,
      'manual-retry',
    );
    harness.manager.dispatchEvent(_manifest().id, 'httpRequest', {
      'requestId': 'manual-retry',
      'endpoint': 'upload',
      'method': 'POST',
      'headers': <String, String>{},
      'body': null,
      'query': <String, String>{},
    });
    final response = await responseFuture;

    expect(response['status'], 200);
    expect(harness.requests, hasLength(2));
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
    'a failed local upload marker does not repeat the remote POST',
    () async {
      final harness = await _load(
        shots: [_shot('uploaded-remotely')],
        responseStatuses: [200, 200],
        annotationStatus: 500,
      );

      expect(await harness.runNextTimer(), isTrue);
      expect(await harness.runNextTimer(), isTrue);

      expect(harness.requests, hasLength(1));
      expect(harness.putBodies(), hasLength(1));
    },
  );

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
