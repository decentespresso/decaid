import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';

import 'plugin_test_helpers.dart';

class FakeCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}

void main() {
  const pluginId = 'proxy.plugin';

  PluginManifest proxyManifest() {
    return PluginManifest(
      id: pluginId,
      name: pluginId,
      author: 'Test',
      description: 'Test',
      version: '1.0.0',
      apiVersion: 1,
      permissions: const {
        PluginPermissions.emit,
        PluginPermissions.proxyDecentApi,
      },
      settings: const {},
      api: PluginApi(endpoints: const []),
    );
  }

  Future<PluginManager> buildManager(
    Future<http.Response> Function(http.Request) onRequest, {
    Duration decentProxyTimeout = const Duration(seconds: 5),
  }) async {
    final store = FakeCredentialStore();
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
    return PluginManager(
      kvStore: FakeKeyValueStoreService(),
      decentProxyTimeout: decentProxyTimeout,
      decentProxyService: DecentProxyService(
        credentialStore: store,
        httpClient: http_testing.MockClient(onRequest),
      ),
    );
  }

  Future<Completer<String>> loadProxyPlugin(PluginManager manager) async {
    final result = Completer<String>();
    final sub = manager.emitStream.listen((e) {
      if (result.isCompleted) return;
      final event = e['event'] as String;
      final payload = e['payload'] as Map<String, dynamic>;
      if (event == 'proxyResult') {
        result.complete('ok');
      } else if (event == 'proxyError') {
        result.complete('err:${payload['message']}');
      }
    });
    result.future.whenComplete(sub.cancel);
    addTearDown(sub.cancel);
    await manager.loadPlugin(
      id: pluginId,
      manifest: proxyManifest(),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$pluginId",
            onLoad() {
              host.decentProxy("support/api/sn")
                .then((response) => host.emit("proxyResult", response))
                .catch((error) => host.emit("proxyError", { message: String(error) }));
            }
          };
        }
      ''',
    );
    return result;
  }

  test('successful proxy call resolves through the owned operation', () async {
    final manager = await buildManager(
      (request) async => http.Response('{"serial":"SN001"}', 200),
    );
    addTearDown(manager.dispose);

    final result = await loadProxyPlugin(manager);
    expect((await result.future.timeout(const Duration(seconds: 5))), 'ok');
    expect(manager.activePendingOpCount, 0);
  });

  test('transport failure rejects the promise', () async {
    final manager = await buildManager(
      (request) async => throw http.ClientException('connection refused'),
    );
    addTearDown(manager.dispose);

    final result = await loadProxyPlugin(manager);
    expect(
      (await result.future.timeout(const Duration(seconds: 5))),
      startsWith('err:'),
    );
    expect(manager.activePendingOpCount, 0);
  });

  test('timeout rejects a slow proxy call', () async {
    final manager = await buildManager((request) async {
      await Future<void>.delayed(const Duration(seconds: 10));
      return http.Response('{"serial":"SN001"}', 200);
    }, decentProxyTimeout: const Duration(milliseconds: 200));
    addTearDown(manager.dispose);

    final result = await loadProxyPlugin(manager);
    final value = await result.future.timeout(const Duration(seconds: 5));
    expect(value, startsWith('err:'));
    expect(value, contains('timed out'));
    expect(manager.activePendingOpCount, 0);
  });

  test('plugin unload rejects pending proxy call', () async {
    final manager = await buildManager((request) async {
      await Future<void>.delayed(const Duration(seconds: 10));
      return http.Response('{"serial":"SN001"}', 200);
    });
    addTearDown(manager.dispose);

    final result = await loadProxyPlugin(manager);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await manager.unloadPlugin(pluginId);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(result.isCompleted, isFalse);
    expect(manager.activePendingOpCount, 0);
  });

  test('cancelAllOperations rejects pending proxy call', () async {
    final manager = await buildManager((request) async {
      await Future<void>.delayed(const Duration(seconds: 10));
      return http.Response('{"serial":"SN001"}', 200);
    });
    addTearDown(manager.dispose);

    final result = await loadProxyPlugin(manager);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    manager.cancelAllOperations();

    final value = await result.future.timeout(const Duration(seconds: 5));
    expect(value, startsWith('err:'));
    expect(manager.activePendingOpCount, 0);
  });

  test('invalid bridge token rejects the promise', () async {
    final manager = await buildManager(
      (request) async => http.Response('{"serial":"SN001"}', 200),
    );
    addTearDown(manager.dispose);

    final result = Completer<String>();
    final sub = manager.emitStream.listen((e) {
      if (result.isCompleted) return;
      final event = e['event'] as String;
      final payload = e['payload'] as Map<String, dynamic>;
      if (event == 'proxyError') result.complete('err:${payload['message']}');
    });
    result.future.whenComplete(sub.cancel);
    await manager.loadPlugin(
      id: pluginId,
      manifest: proxyManifest(),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$pluginId",
            onLoad() {
              globalThis.__reaprimePluginBridge.decentProxy(
                "$pluginId", 0, "bogus-token", "support/api/sn"
              )
                .then(() => host.emit("proxyResult", {}))
                .catch((error) => host.emit("proxyError", { message: String(error) }));
            }
          };
        }
      ''',
    );

    final value = await result.future.timeout(const Duration(seconds: 5));
    expect(value, startsWith('err:'));
    expect(manager.activePendingOpCount, 0);
  });

  test('late response from a previous plugin generation is dropped', () async {
    var calls = 0;
    final manager = await buildManager((request) async {
      calls += 1;
      if (calls == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
        return http.Response('{"serial":"OLD-GEN"}', 200);
      }
      return http.Response('{"serial":"NEW-GEN"}', 200);
    });
    addTearDown(manager.dispose);

    final firstGen = await loadProxyPlugin(manager);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await manager.unloadPlugin(pluginId);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(firstGen.isCompleted, isFalse);

    final secondGen = await loadProxyPlugin(manager);
    expect((await secondGen.future.timeout(const Duration(seconds: 5))), 'ok');

    // The old generation's late response must be dropped, not delivered.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(manager.activePendingOpCount, 0);
    expect(calls, 2);
  });
}
