import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

/// TLS transport tests.
///
/// The positive round-trip path (a certificate signed by a trust anchor the
/// platform accepts) cannot be exercised offline: dart:io on this platform
/// does not honor user-supplied trust anchors for `SecureSocket.connect`
/// (verified separately; public-host TLS validation works, so the production
/// path uses the platform trust store as designed). These tests therefore
/// cover the TLS branch end to end through the rejection path: an untrusted
/// self-signed certificate must fail platform validation and reject `open()`.
Future<Object?> runPluginResult(
  PluginManager manager, {
  required String id,
  required String jsBody,
  Set<PluginPermissions>? permissions,
}) async {
  final result = Completer<Object?>();
  final sub = manager.emitStream.listen((e) {
    if (!result.isCompleted) result.complete(e['payload']);
  });
  addTearDown(sub.cancel);
  await manager.loadPlugin(
    id: id,
    manifest: permissions == null
        ? testManifest(id)
        : testManifest(id, permissions: permissions),
    settings: {},
    jsCode:
        '''
      function createPlugin(host) {
        return {
          id: "$id",
          onLoad() {
            $jsBody
          }
        };
      }
    ''',
  );
  return result.future.timeout(const Duration(seconds: 10));
}

void main() {
  late PluginManager manager;
  var certsReady = false;
  late String serverCert;
  late String serverKey;

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('plugin_tls_certs');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    serverCert = '${dir.path}/server_cert.pem';
    serverKey = '${dir.path}/server_key.pem';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-keyout',
      serverKey,
      '-out',
      serverCert,
      '-days',
      '2',
      '-nodes',
      '-subj',
      '/CN=localhost',
    ]);
    certsReady = result.exitCode == 0;
  });

  setUp(() {
    manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      fetchTimeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async => manager.dispose());

  test(
    'tls open rejects an untrusted certificate via platform validation',
    () async {
      if (!certsReady) {
        markTestSkipped('openssl unavailable');
        return;
      }
      final serverContext = SecurityContext()
        ..useCertificateChain(serverCert)
        ..usePrivateKey(serverKey);
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      server.listen(
        (socket) => socket.listen(
          (chunk) {},
          onError: (Object _) {},
          cancelOnError: true,
        ),
        onError: (Object _) {},
      );
      addTearDown(() async => server.close());

      final result = await runPluginResult(
        manager,
        id: 'tls.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkTls,
        },
        jsBody:
            '''
        host.transport.open({
          kind: "tls",
          host: "127.0.0.1",
          port: ${server.port}
        }).then(
          () => host.emit("result", "unexpected"),
          (e) => host.emit("result", JSON.stringify({ message: e.message }))
        );
      ''',
      );

      final error = jsonDecode(result as String) as Map<String, dynamic>;
      expect(error['message'], contains('HandshakeException'));
      expect(manager.liveTransportCount, 0);
    },
  );

  test(
    'wss rejects an untrusted certificate using only network.websocket',
    () async {
      if (!certsReady) {
        markTestSkipped('openssl unavailable');
        return;
      }
      final serverContext = SecurityContext()
        ..useCertificateChain(serverCert)
        ..usePrivateKey(serverKey);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      server.listen((req) async {
        try {
          if (WebSocketTransformer.isUpgradeRequest(req)) {
            final ws = await WebSocketTransformer.upgrade(req);
            ws.listen((data) {}, onError: (Object _) {});
          } else {
            req.response.statusCode = 404;
            await req.response.close();
          }
        } catch (_) {}
      });
      addTearDown(() async => server.close(force: true));

      final result = await runPluginResult(
        manager,
        id: 'wss.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        jsBody:
            '''
        host.transport.open({
          kind: "websocket",
          url: "wss://127.0.0.1:${server.port}/x"
        }).then(
          () => host.emit("result", "unexpected"),
          (e) => host.emit("result", JSON.stringify({ message: e.message }))
        );
      ''',
      );

      final error = jsonDecode(result as String) as Map<String, dynamic>;
      expect(error['message'], contains('HandshakeException'));
      expect(manager.liveTransportCount, 0);
    },
  );
}
