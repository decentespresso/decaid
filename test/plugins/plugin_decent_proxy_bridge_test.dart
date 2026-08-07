import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:logging/logging.dart';
import 'package:reaprime/src/plugins/plugin_decent_proxy_bridge.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';

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
  late FakeCredentialStore store;

  setUp(() {
    store = FakeCredentialStore();
  });

  Future<void> linkAccount() async {
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
  }

  PluginManifest manifestWith(Set<PluginPermissions> permissions) {
    return PluginManifest(
      id: 'test.plugin',
      name: 'Test Plugin',
      author: 'Test',
      description: 'Test',
      version: '1.0.0',
      apiVersion: 1,
      permissions: permissions,
      settings: {},
      api: PluginApi(endpoints: []),
    );
  }

  PluginDecentProxyBridge bridge(http_testing.MockClientHandler handler) {
    return PluginDecentProxyBridge(
      decentProxyService: DecentProxyService(
        httpClient: http_testing.MockClient(handler),
        credentialStore: store,
      ),
    );
  }

  test('declared permission forwards GET through DecentProxyService', () async {
    await linkAccount();
    late http.Request upstream;
    final records = <LogRecord>[];
    final sub = Logger('DecentProxy').onRecord.listen(records.add);
    addTearDown(sub.cancel);

    final result =
        await bridge((request) async {
          upstream = request;
          return http.Response(
            'SN001',
            200,
            headers: {'content-type': 'text/plain'},
          );
        }).proxyForPlugin(
          pluginId: 'test.plugin',
          manifest: manifestWith({PluginPermissions.proxyDecentApi}),
          path: 'support/api/sn',
          query: {'onlyespressomachines': '1'},
        );

    expect(result['status'], 200);
    expect(result['body'], 'SN001');
    expect(result['headers'], containsPair('content-type', 'text/plain'));
    expect(
      upstream.url.toString(),
      'https://decentespresso.com/support/api/sn?onlyespressomachines=1',
    );
    expect(
      upstream.headers['authorization'],
      'Basic ${base64Encode(utf8.encode('user@example.com:cryptpw_abc123'))}',
    );
    expect(
      records.any((r) => r.message.contains('plugin:test.plugin')),
      isTrue,
    );
  });

  test(
    'declared permission forwards POST with body through DecentProxyService',
    () async {
      await linkAccount();
      late http.Request upstream;

      final result =
          await bridge((request) async {
            upstream = request;
            return http.Response(
              '{"ok":true,"profile_ref":"adaptive_v2@abc"}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }).proxyForPlugin(
            pluginId: 'test.plugin',
            manifest: manifestWith({PluginPermissions.proxyDecentApiWrite}),
            path: 'support/api/shot_upload',
            method: 'POST',
            body: '{"id":"decaid-1","machine":{"serialNumber":"6262"}}',
            contentType: 'application/json',
          );

      expect(result['status'], 200);
      expect(result['body'], contains('profile_ref'));
      expect(upstream.method, 'POST');
      expect(
        upstream.url.toString(),
        'https://decentespresso.com/support/api/shot_upload',
      );
      expect(
        upstream.body,
        '{"id":"decaid-1","machine":{"serialNumber":"6262"}}',
      );
      expect(upstream.headers['content-type'], contains('application/json'));
      expect(
        upstream.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('user@example.com:cryptpw_abc123'))}',
      );
    },
  );

  test('POST without the write permission is rejected', () async {
    await linkAccount();
    var upstreamCalled = false;
    await expectLater(
      bridge((request) async {
        upstreamCalled = true;
        return http.Response('must not happen', 200);
      }).proxyForPlugin(
        pluginId: 'test.plugin',
        manifest: manifestWith({PluginPermissions.proxyDecentApi}),
        path: 'support/api/shot_upload',
        method: 'POST',
        body: '{}',
      ),
      throwsA(isA<StateError>()),
    );
    expect(upstreamCalled, isFalse);
  });

  test('POST to a path outside the write allowlist is rejected', () async {
    await linkAccount();
    var upstreamCalled = false;
    await expectLater(
      bridge((request) async {
        upstreamCalled = true;
        return http.Response('must not happen', 200);
      }).proxyForPlugin(
        pluginId: 'test.plugin',
        manifest: manifestWith({PluginPermissions.proxyDecentApiWrite}),
        path: 'support/api/some_other_write',
        method: 'POST',
        body: '{}',
      ),
      throwsA(isA<StateError>()),
    );
    expect(upstreamCalled, isFalse);
  });

  test('PUT (and other non-GET/POST methods) are unsupported', () async {
    await linkAccount();
    var upstreamCalled = false;
    await expectLater(
      bridge((request) async {
        upstreamCalled = true;
        return http.Response('must not happen', 200);
      }).proxyForPlugin(
        pluginId: 'test.plugin',
        manifest: manifestWith({PluginPermissions.proxyDecentApiWrite}),
        path: 'support/api/shot_upload',
        method: 'PUT',
        body: '{}',
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(upstreamCalled, isFalse);
  });

  test('missing permission rejects before upstream is called', () async {
    await linkAccount();
    var upstreamCalled = false;

    await expectLater(
      bridge((request) async {
        upstreamCalled = true;
        return http.Response('must not happen', 200);
      }).proxyForPlugin(
        pluginId: 'test.plugin',
        manifest: manifestWith({}),
        path: 'support/api/sn',
      ),
      throwsA(isA<StateError>()),
    );

    expect(upstreamCalled, isFalse);
  });

  test('credentials are not returned to plugin-visible data', () async {
    await linkAccount();

    final result =
        await bridge((request) async {
          return http.Response(
            'ok',
            200,
            headers: {'authorization': 'Basic leaked'},
          );
        }).proxyForPlugin(
          pluginId: 'test.plugin',
          manifest: manifestWith({PluginPermissions.proxyDecentApi}),
          path: 'support/api/sn',
        );

    final serialized = jsonEncode(result);
    expect(serialized.contains('cryptpw_abc123'), isFalse);
    expect(serialized.toLowerCase().contains('authorization'), isFalse);
  });
}
