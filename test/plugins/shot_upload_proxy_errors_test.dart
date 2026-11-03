import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';

import 'plugin_manager_decent_proxy_bridge_test.dart' as bridge;
import 'plugin_test_helpers.dart';

void main() {
  for (final linked in [false, true]) {
    test(
      'proxy reports an authentication code for ${linked ? 'invalid' : 'missing'} credentials without an upstream request',
      () async {
        final credentials = bridge.FakeCredentialStore();
        if (linked) {
          await credentials.write(key: 'email', value: 'test@example.com');
          await credentials.write(key: 'password', value: 'test-token');
        }
        var upstreamCalls = 0;
        final manager = PluginManager(
          kvStore: FakeKeyValueStoreService(),
          decentProxyService: DecentProxyService(
            credentialStore: credentials,
            requireConsent: (_) async => true,
            isAuthKnownInvalid: () async => linked,
            httpClient: MockClient((_) async {
              upstreamCalls++;
              return http.Response('', 200);
            }),
          ),
        );
        addTearDown(manager.dispose);
        final event = manager.emitStream.first;
        await manager.loadPlugin(
          id: 'uploader.reaplugin',
          manifest: testManifest(
            'uploader.reaplugin',
            permissions: {
              PluginPermissions.emit,
              PluginPermissions.proxyDecentApi,
            },
          ),
          settings: {},
          jsCode: '''
function createPlugin(host) {
  return { id: "uploader.reaplugin", onLoad() {
    host.decentProxy("support/api/sn", { method: "GET" })
      .catch(error => host.emit("failure", { code: error.code }));
  } };
}
''',
        );
        final result = await event.timeout(const Duration(seconds: 5));
        expect(result['payload'], {'code': 'account_authentication_required'});
        expect(upstreamCalls, 0);
      },
    );
  }
}
