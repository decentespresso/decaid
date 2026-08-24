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

Map<String, dynamic> _shot(String id) => {
  'id': id,
  'timestamp': '2026-01-01T00:00:00Z',
  'annotations': <String, dynamic>{},
  'workflow': {
    'profile': {'title': 'Damian LRv3', 'steps': <dynamic>[]},
    'context': <String, dynamic>{},
    'machine': {
      'serialNumber': '6262',
      'model': 'DE1Pro',
      'firmwareVersion': '1293',
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
  }) async {
    final store = _FakeCredentialStore();
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');

    final manager = PluginManager(
      kvStore: _FakeKeyValueStore(),
      decentProxyService: DecentProxyService(
        credentialStore: store,
        requireConsent: (_) async => true,
        httpClient: http_testing.MockClient((request) async {
          captured.add(request);
          return http.Response(
            jsonEncode({'ok': true, 'profile_ref': 'damian@1'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );
    final r = manager.js.evaluate('''
      globalThis.__timerSet = (pluginId, generation, callback, delay) => 1;
      globalThis.__timerClear = () => {};
      globalThis.__puts = [];
      globalThis.__fetches = [];
      globalThis.__fetchFor = async (pluginId, generation, url, init) => {
        init = init || {};
        globalThis.__fetches.push(String(url));
        if (init.method === 'PUT') { globalThis.__puts.push({ url: String(url), body: init.body }); return { ok:true, status:200, json: async () => ({}) }; }
        if (url.endsWith('/shots/latest')) return { ok:true, json: async () => ({ id:'shot-1' }) };
        if (url.endsWith('/shots/shot-1')) return { ok:true, json: async () => (${jsonEncode(_shot('shot-1'))}) };
        if (url.endsWith('/machine/info')) return { ok:true, json: async () => ({ serialNumber:'6262', version:'1293', model:'DE1Pro' }) };
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
      expect(body['machine']['serialNumber'], '6262');
      expect(body['machine']['firmwareVersion'], '1293');
      expect(body['machine'].containsKey('bleId'), isFalse);
      expect(body['app']['version'], '9.9.9');
      final fetches =
          jsonDecode(
                manager.js
                    .evaluate('JSON.stringify(globalThis.__fetches)')
                    .stringResult,
              )
              as List;
      expect(
        fetches.where((url) => url.toString().endsWith('/machine/info')),
        isEmpty,
      );

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
