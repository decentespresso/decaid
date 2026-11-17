import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';

import 'plugin_test_helpers.dart';

class FakeCredentialStore implements CredentialStore {
  @override
  Future<String?> read({required String key}) async => switch (key) {
    'email' => 'user@example.com',
    'password' => 'test-password',
    _ => null,
  };

  @override
  Future<void> write({required String key, required String value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

void main() {
  final body = jsonEncode({'notes': 'x' * 2048});

  Future<Map<String, dynamic>> callProxy(
    Map<String, dynamic> options,
    List<http.Request> captured, {
    String? gzipExpression,
  }) async {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      decentProxyService: DecentProxyService(
        httpClient: http_testing.MockClient((request) async {
          captured.add(request);
          return http.Response('{"ok":true}', 201);
        }),
        credentialStore: FakeCredentialStore(),
        requireConsent: (_) async => true,
      ),
    );
    addTearDown(manager.dispose);
    final result = Completer<Map<String, dynamic>>();
    final subscription = manager.emitStream.listen((event) {
      if (event['event'] == 'result' && !result.isCompleted) {
        result.complete(event['payload'] as Map<String, dynamic>);
      }
    });
    addTearDown(subscription.cancel);
    await manager.loadPlugin(
      id: 'gzip.plugin',
      manifest: PluginManifest(
        id: 'gzip.plugin',
        name: 'Gzip test',
        author: 'Test',
        description: 'Test',
        version: '1.0.0',
        apiVersion: 1,
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.proxyDecentApiWrite,
        },
        settings: const {},
        api: PluginApi(endpoints: const []),
      ),
      settings: const {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "gzip.plugin",
            onLoad() {
              host.decentProxy("support/api/shot_upload", {
                ...${jsonEncode(options)},
                ${gzipExpression == null ? '' : 'gzip: $gzipExpression'}
              })
                .then((response) => host.emit("result", {status: response.status}))
                .catch((error) => host.emit("result", {error: String(error)}));
            }
          };
        }
      ''',
    );
    return result.future.timeout(const Duration(seconds: 5));
  }

  for (final mode in ['omitted', 'false', 'true']) {
    test('JS proxy gzip $mode preserves explicit opt-in', () async {
      final captured = <http.Request>[];
      final result = await callProxy({
        'method': 'POST',
        'contentType': 'application/json',
        'body': body,
        if (mode != 'omitted') 'gzip': mode == 'true',
      }, captured);

      expect(result, {'status': 201});
      final request = captured.single;
      if (mode == 'true') {
        expect(request.headers['content-encoding'], 'gzip');
        expect(gzip.decode(request.bodyBytes), utf8.encode(body));
      } else {
        expect(request.headers.containsKey('content-encoding'), isFalse);
        expect(request.bodyBytes, utf8.encode(body));
      }
    });
  }

  for (final invalid in [null, 'true', 1, <Object>[]]) {
    test('rejects non-boolean JS gzip ${jsonEncode(invalid)}', () async {
      final captured = <http.Request>[];
      final result = await callProxy({
        'method': 'POST',
        'contentType': 'application/json',
        'body': body,
        'gzip': invalid,
      }, captured);

      expect(result['error'], isNotEmpty);
      expect(captured, isEmpty);
    });
  }

  for (final invalid in ['() => true', 'Symbol("gzip")']) {
    test('rejects non-serializable JS gzip $invalid', () async {
      final captured = <http.Request>[];
      final result = await callProxy(
        {'method': 'POST', 'body': body},
        captured,
        gzipExpression: invalid,
      );

      expect(result['error'], isNotEmpty);
      expect(captured, isEmpty);
    });
  }
}
