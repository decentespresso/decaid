import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';

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

class FakeKeyValueStoreService implements KeyValueStoreService {
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
  }) async {
    return _store[namespace]?.remove(key) != null;
  }

  @override
  Future<Object?> get({
    String namespace = 'default',
    required String key,
  }) async {
    return _store[namespace]?[key];
  }

  @override
  Future<List<String>> keys({String namespace = 'default'}) async {
    return _store[namespace]?.keys.toList() ?? [];
  }

  @override
  List<String> get namespaces => _store.keys.toList();

  @override
  Future<Map<String, Object>> getAll({String namespace = 'default'}) async {
    return Map<String, Object>.from(_store[namespace] ?? {});
  }
}

void main() {
  PluginManifest manifest({
    required String id,
    Set<PluginPermissions> permissions = const {PluginPermissions.emit},
  }) {
    return PluginManifest(
      id: id,
      name: id,
      author: 'Test',
      description: 'Test',
      version: '1.0.0',
      apiVersion: 1,
      permissions: permissions,
      settings: {},
      api: PluginApi(endpoints: []),
    );
  }

  test(
    'Decent proxy bridge token and responses are not observable through globals',
    () async {
      final credentialStore = FakeCredentialStore();
      await credentialStore.write(key: 'email', value: 'user@example.com');
      await credentialStore.write(key: 'password', value: 'cryptpw_abc123');

      var upstreamCalls = 0;
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        decentProxyService: DecentProxyService(
          credentialStore: credentialStore,
          requireConsent: (_) async => true,
          httpClient: http_testing.MockClient((request) async {
            upstreamCalls += 1;
            return http.Response(
              jsonEncode({'serial': 'SN001'}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ),
      );

      await manager.loadPlugin(
        id: 'spy.plugin',
        manifest: manifest(id: 'spy.plugin'),
        settings: {},
        jsCode: r'''
          function createPlugin(host) {
            const spy = globalThis.__spy = {
              tokenCount: 0,
              responseCount: 0,
              canReplaceBridgeMethod: false,
              hasLegacyProxyHook: typeof globalThis.host.decentProxy === "function",
              hasLegacyResponseHook: typeof globalThis.__handleDecentProxyResponse === "function"
            };

            const legacyProxy = globalThis.host.decentProxy;
            if (typeof legacyProxy === "function") {
              globalThis.host.decentProxy = function (...args) {
                spy.tokenCount += 1;
                return legacyProxy.apply(this, args);
              };
            }

            const legacyResponse = globalThis.__handleDecentProxyResponse;
            if (typeof legacyResponse === "function") {
              globalThis.__handleDecentProxyResponse = function (...args) {
                spy.responseCount += 1;
                return legacyResponse.apply(this, args);
              };
            }

            const originalThen = Promise.prototype.then;
            Promise.prototype.then = function (onFulfilled, onRejected) {
              return originalThen.call(this, function (value) {
                if (value && value.status === 200 && value.body === '{"serial":"SN001"}') {
                  spy.responseCount += 1;
                }
                return typeof onFulfilled === "function"
                  ? onFulfilled(value)
                  : value;
              }, onRejected);
            };

            function wrapPending(value) {
              if (value && typeof value.resolve === "function" && !value.__spyWrapped) {
                const originalResolve = value.resolve;
                value.__spyWrapped = true;
                value.resolve = function (response) {
                  if (response && response.status === 200 && response.body === '{"serial":"SN001"}') {
                    spy.responseCount += 1;
                  }
                  return originalResolve(response);
                };
              }
              return value;
            }

            const originalMapSet = Map.prototype.set;
            Map.prototype.set = function (key, value) {
              return originalMapSet.call(this, key, wrapPending(value));
            };

            const originalMapGet = Map.prototype.get;
            Map.prototype.get = function (key) {
              return wrapPending(originalMapGet.call(this, key));
            };

            const bridge = globalThis.__reaprimePluginBridge;
            if (bridge) {
              const original = bridge.decentProxy;
              try {
                bridge.decentProxy = function (...args) {
                  spy.tokenCount += 1;
                  return original.apply(this, args);
                };
              } catch (e) {
                // Non-strict runtimes may throw for frozen properties.
              }
              spy.canReplaceBridgeMethod = bridge.decentProxy !== original;
            }

            return {
              id: "spy.plugin",
              onEvent(evt) {
                if (evt.name === "report") {
                  host.emit("spyReport", spy);
                }
              }
            };
          }
        ''',
      );

      final proxyResult = expectLater(
        manager.emitStream,
        emits(
          allOf(
            containsPair('pluginId', 'privileged.plugin'),
            containsPair('event', 'proxyResult'),
            containsPair(
              'payload',
              allOf(
                containsPair('status', 200),
                containsPair('body', '{"serial":"SN001"}'),
              ),
            ),
          ),
        ),
      );

      await manager.loadPlugin(
        id: 'privileged.plugin',
        manifest: manifest(
          id: 'privileged.plugin',
          permissions: {
            PluginPermissions.emit,
            PluginPermissions.proxyDecentApi,
          },
        ),
        settings: {},
        jsCode: r'''
          function createPlugin(host) {
            return {
              id: "privileged.plugin",
              onLoad() {
                host.decentProxy("support/api/sn", {
                  query: { onlyespressomachines: "1" }
                }).then((response) => {
                  host.emit("proxyResult", response);
                }).catch((error) => {
                  host.emit("proxyError", { message: String(error) });
                });
              }
            };
          }
        ''',
      );

      await proxyResult.timeout(const Duration(seconds: 5));
      expect(upstreamCalls, 1);

      final spyReport = expectLater(
        manager.emitStream,
        emits(
          allOf(
            containsPair('pluginId', 'spy.plugin'),
            containsPair('event', 'spyReport'),
            containsPair(
              'payload',
              allOf(
                containsPair('tokenCount', 0),
                containsPair('responseCount', 0),
                containsPair('canReplaceBridgeMethod', false),
                containsPair('hasLegacyProxyHook', false),
                containsPair('hasLegacyResponseHook', false),
              ),
            ),
          ),
        ),
      );

      manager.dispatchEvent('spy.plugin', 'report', {});
      await spyReport.timeout(const Duration(seconds: 5));
    },
  );
}
