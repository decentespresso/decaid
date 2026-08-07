import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

void main() {
  late PluginManager manager;

  Future<HttpServer> startServer(
    Future<void> Function(HttpResponse) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      try {
        await handler(req.response);
        await req.response.close();
      } catch (_) {
        try {
          req.response.close();
        } catch (_) {}
      }
    });
    return server;
  }

  setUp(() {
    manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      fetchTimeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async => manager.dispose());

  Future<String> runFetch(
    String url, {
    Map<String, dynamic>? init,
    Duration? wait,
    Set<PluginPermissions>? permissions,
  }) async {
    final result = Completer<String>();
    await manager.loadPlugin(
      id: 'fetch.plugin',
      manifest: permissions == null
          ? testManifest('fetch.plugin')
          : testManifest('fetch.plugin', permissions: permissions),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "fetch.plugin",
            onLoad() {
              fetch(${jsonEncode(url)}, ${jsonEncode(init ?? {})})
                .then((res) => res.text())
                .then((text) => host.emit("result", "ok:" + text))
                .catch((e) => host.emit("result", "err:" + e.name + ":" + e.message));
            }
          };
        }
      ''',
    );
    final sub = manager.emitStream.listen((e) {
      if (!result.isCompleted) result.complete(e['payload'] as String);
    });
    final value = await result.future
        .timeout(wait ?? const Duration(seconds: 10))
        .whenComplete(sub.cancel);
    await sub.cancel();
    return value;
  }

  test('successful fetch resolves with body', () async {
    final server = await startServer((res) async {
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'hello': 'world'}));
    });
    addTearDown(server.close);

    final result = await runFetch('http://127.0.0.1:${server.port}/data');

    expect(result, 'ok:{"hello":"world"}');
    expect(manager.activePendingOpCount, 0);
  });

  test('fetch rejects without api permission before network access', () async {
    var requests = 0;
    final server = await startServer((res) async {
      requests += 1;
      res.write('unexpected');
    });
    addTearDown(server.close);

    final result = await runFetch(
      'http://127.0.0.1:${server.port}/data',
      permissions: const {PluginPermissions.emit},
    );

    expect(result, contains('PluginPermissionError'));
    expect(result, contains('api'));
    expect(requests, 0);
  });

  test('Dart rejects direct fetch bridge calls without api', () async {
    var requests = 0;
    final server = await startServer((res) async {
      requests += 1;
      res.write('unexpected');
    });
    addTearDown(server.close);
    final result = Completer<String>();
    final subscription = manager.emitStream.listen((event) {
      if (!result.isCompleted) result.complete(event['payload'] as String);
    });
    addTearDown(subscription.cancel);

    await manager.loadPlugin(
      id: 'fetch.plugin',
      manifest: testManifest(
        'fetch.plugin',
        permissions: const {PluginPermissions.emit},
      ),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "fetch.plugin",
            onLoad() {
              globalThis.__reaprimePluginHostBridge.fetch(
                pluginBridgeToken,
                1,
                "http://127.0.0.1:${server.port}/data"
              )
                .then(() => host.emit("result", "unexpected"))
                .catch((error) => host.emit("result", String(error)));
            }
          };
        }
      ''',
    );

    expect(
      await result.future.timeout(const Duration(seconds: 5)),
      contains('api'),
    );
    expect(requests, 0);
  });

  test(
    'non-2xx response resolves (fetch semantics) with status exposed',
    () async {
      final server = await startServer((res) async {
        res.statusCode = 404;
        res.write('nope');
      });
      addTearDown(server.close);

      final result = await runFetch('http://127.0.0.1:${server.port}/missing');

      expect(result, 'ok:nope');
      expect(manager.activePendingOpCount, 0);
    },
  );

  test('connection failure rejects the promise', () async {
    final result = await runFetch('http://127.0.0.1:1/nowhere');

    expect(result, startsWith('err:'));
    expect(manager.activePendingOpCount, 0);
  });

  test('request timeout rejects the promise', () async {
    final server = await startServer((res) async {
      await Future<void>.delayed(const Duration(seconds: 10));
      res.write('too late');
    });
    addTearDown(server.close);

    final result = await runFetch('http://127.0.0.1:${server.port}/slow');

    expect(result, startsWith('err:'));
    expect(manager.activePendingOpCount, 0);
  });

  test('oversized response rejects the promise', () async {
    final server = await startServer((res) async {
      res.write('x' * 1024);
    });
    addTearDown(server.close);
    manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      fetchTimeout: const Duration(seconds: 2),
      maxFetchResponseBytes: 100,
    );

    final result = await runFetch('http://127.0.0.1:${server.port}/big');

    expect(result, startsWith('err:'));
    expect(manager.activePendingOpCount, 0);
  });

  test('invalid UTF-8 body decodes with replacement characters', () async {
    final server = await startServer((res) async {
      res.add([0xFF, 0xFE, 0x41]);
    });
    addTearDown(server.close);

    final result = await runFetch('http://127.0.0.1:${server.port}/bytes');

    expect(result, contains('\uFFFD'));
    expect(manager.activePendingOpCount, 0);
  });

  test('global fetch (no plugin context) rejects instead of leaking', () async {
    final result = Completer<String>();
    final sub = manager.emitStream.listen((e) {
      if (!result.isCompleted) result.complete(e['payload'] as String);
    });
    await manager.loadPlugin(
      id: 'fetch.plugin',
      manifest: testManifest('fetch.plugin'),
      settings: {},
      jsCode: '''
        function createPlugin(host) {
          return {
            id: "fetch.plugin",
            onLoad() {
              globalThis.fetch("http://127.0.0.1:1/x")
                .then(() => host.emit("result", "resolved"))
                .catch((e) => host.emit("result", "err:" + e.message));
            }
          };
        }
      ''',
    );

    final value = await result.future
        .timeout(const Duration(seconds: 5))
        .whenComplete(sub.cancel);
    await sub.cancel();

    expect(value, startsWith('err:'));
    expect(value, contains('only available to plugins'));
    expect(manager.activePendingOpCount, 0);
  });

  test('plugin unload rejects pending fetch', () async {
    final server = await startServer((res) async {
      await Future<void>.delayed(const Duration(seconds: 10));
      res.write('late');
    });
    addTearDown(server.close);

    await manager.loadPlugin(
      id: 'fetch.plugin',
      manifest: testManifest('fetch.plugin'),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "fetch.plugin",
            onLoad() {
              fetch(${jsonEncode('http://127.0.0.1:${server.port}/pending')})
                .then((res) => host.emit("result", "unexpected"))
                .catch((e) => host.emit("result", "rejected:" + e.message));
            }
          };
        }
      ''',
    );
    final result = Completer<String>();
    final sub = manager.emitStream.listen((e) {
      if (!result.isCompleted) result.complete(e['payload'] as String);
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await manager.unloadPlugin('fetch.plugin');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(result.isCompleted, isFalse);
    expect(manager.activePendingOpCount, 0);
    await sub.cancel();
  });

  test(
    'fetch from a previous plugin generation does not hit the network',
    () async {
      var requests = 0;
      final server = await startServer((res) async {
        requests += 1;
        await Future<void>.delayed(const Duration(seconds: 10));
        res.write('late');
      });
      addTearDown(server.close);

      await manager.loadPlugin(
        id: 'fetch.plugin',
        manifest: testManifest('fetch.plugin'),
        settings: {},
        jsCode:
            '''
        function createPlugin(host) {
          return {
            id: "fetch.plugin",
            onLoad() {
              fetch(${jsonEncode('http://127.0.0.1:${server.port}/slow')})
                .then(() => host.emit("result", "unexpected"))
                .catch((e) => host.emit("result", "err:" + e.message));
            }
          };
        }
      ''',
      );
      await manager.unloadPlugin('fetch.plugin');
      await manager.loadPlugin(
        id: 'fetch.plugin',
        manifest: testManifest('fetch.plugin'),
        settings: {},
        jsCode:
            'function createPlugin(host) { return { id: "fetch.plugin" }; }',
      );

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(requests, 0);
      expect(manager.activePendingOpCount, 0);
    },
  );

  test('cancelAllOperations rejects pending fetch', () async {
    final server = await startServer((res) async {
      await Future<void>.delayed(const Duration(seconds: 10));
      res.write('late');
    });
    addTearDown(server.close);

    await manager.loadPlugin(
      id: 'fetch.plugin',
      manifest: testManifest('fetch.plugin'),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "fetch.plugin",
            onLoad() {
              fetch(${jsonEncode('http://127.0.0.1:${server.port}/pending')})
                .then((res) => host.emit("result", "unexpected"))
                .catch((e) => host.emit("result", "rejected:" + e.message));
            }
          };
        }
      ''',
    );
    final result = Completer<String>();
    final sub = manager.emitStream.listen((e) {
      if (!result.isCompleted) result.complete(e['payload'] as String);
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    manager.cancelAllOperations();
    final value = await result.future
        .timeout(const Duration(seconds: 5))
        .whenComplete(sub.cancel);

    expect(value, startsWith('rejected:'));
    expect(manager.activePendingOpCount, 0);
  });
}
