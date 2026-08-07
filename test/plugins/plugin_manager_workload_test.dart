import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'plugin_test_helpers.dart';

void main() {
  const pluginId = 'workload.plugin';

  PluginManifest manifest() {
    return PluginManifest(
      id: pluginId,
      name: pluginId,
      author: 'Test',
      description: 'Test',
      version: '1.0.0',
      apiVersion: 1,
      permissions: const {
        PluginPermissions.api,
        PluginPermissions.emit,
        PluginPermissions.proxyDecentApi,
      },
      settings: const {},
      api: PluginApi(endpoints: const []),
    );
  }

  test(
    'repeated timer/fetch/proxy workload returns all registries to zero',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"ok":true}');
        await req.response.close();
      });
      addTearDown(server.close);

      final store = _CredentialStore();
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        fetchTimeout: const Duration(seconds: 5),
        pluginHttpTimeout: const Duration(seconds: 5),
        decentProxyTimeout: const Duration(seconds: 5),
        decentProxyService: DecentProxyService(
          credentialStore: store,
          httpClient: http_testing.MockClient(
            (request) async => http.Response('{"serial":"SN001"}', 200),
          ),
        ),
      );
      addTearDown(manager.dispose);

      final done = Completer<void>();
      final sub = manager.emitStream.listen((e) {
        final event = e['event'] as String;
        if (event == 'finished' && !done.isCompleted) done.complete();
      });

      for (var round = 0; round < 10; round++) {
        await manager.loadPlugin(
          id: pluginId,
          manifest: manifest(),
          settings: {},
          jsCode:
              '''
            function createPlugin(host) {
              return {
                id: "$pluginId",
                onLoad() {
                  const timers = [
                    setTimeout(() => host.emit("t1", "fired"), 20),
                    setTimeout(() => host.emit("t2", "fired"), 30)
                  ];
                  fetch("http://127.0.0.1:${server.port}/data")
                    .then((r) => r.text())
                    .then(() => host.decentProxy("support/api/sn"))
                    .then(() => {
                      clearTimeout(timers[0]);
                      clearTimeout(timers[1]);
                      host.emit("finished", "round");
                    })
                    .catch((e) => host.emit("finished", "error:" + e.message));
                }
              };
            }
          ''',
        );
        await done.future.timeout(const Duration(seconds: 10));
        if (!done.isCompleted) done.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(manager.activeTimerCount, 0, reason: 'timers in round $round');
        expect(
          manager.activePendingOpCount,
          0,
          reason: 'pending ops in round $round',
        );
        await manager.unloadPlugin(pluginId);
        expect(
          manager.activeTimerCount,
          0,
          reason: 'timers after unload in round $round',
        );
        expect(
          manager.activePendingOpCount,
          0,
          reason: 'ops after unload in round $round',
        );
      }
      await sub.cancel();
      expect(manager.activeTimersByPlugin, isEmpty);
      expect(manager.activePendingOpsByType, isEmpty);
    },
  );
}

class _CredentialStore implements CredentialStore {
  @override
  Future<String?> read({required String key}) async => 'value';

  @override
  Future<void> write({required String key, required String value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}
