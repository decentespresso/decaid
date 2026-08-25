import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

import '../../plugins/plugin_test_helpers.dart';

class _FakePluginLoaderService extends Fake implements PluginLoaderService {}

class _SettingsPluginLoaderService extends Fake implements PluginLoaderService {
  Map<String, dynamic> publicSettings = {
    'Username': 'user',
    'Password': {'isSet': true},
  };
  Map<String, dynamic>? savedPatch;
  int reloadCalls = 0;

  @override
  Future<Map<String, dynamic>> pluginSettings(String pluginId) async =>
      publicSettings;

  @override
  Future<void> savePluginSettings(
    String pluginId,
    Map<String, dynamic> settings,
  ) async {
    savedPatch = settings;
  }

  @override
  Future<void> reloadPlugin(String pluginId) async {
    reloadCalls += 1;
  }
}

void main() {
  const pluginId = 'http.plugin';

  PluginManifest httpManifest({
    Set<PluginPermissions> permissions = const {PluginPermissions.api},
  }) {
    return PluginManifest(
      id: pluginId,
      name: pluginId,
      author: 'Test',
      description: 'Test',
      version: '1.0.0',
      apiVersion: 1,
      permissions: permissions,
      settings: const {},
      api: PluginApi(
        endpoints: [
          ApiEndpoint(id: 'hello', type: ApiEndpointType.http, data: const {}),
        ],
      ),
    );
  }

  group('plugin settings API', () {
    late PluginManager manager;
    late _SettingsPluginLoaderService pluginService;
    late RouterPlus app;

    setUp(() {
      manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.cancelAllOperations);
      pluginService = _SettingsPluginLoaderService();
      app = Router().plus;
      PluginsHandler(
        pluginManager: manager,
        pluginService: pluginService,
      ).addRoutes(app);
    });

    test('GET returns secure state without the credential', () async {
      final response = await app.call(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/plugins/$pluginId/settings'),
        ),
      );

      expect(response.statusCode, 200);
      expect(jsonDecode(await response.readAsString()), {
        'Username': 'user',
        'Password': {'isSet': true},
      });
    });

    test('POST never echoes a submitted credential', () async {
      final response = await app.call(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/plugins/$pluginId/settings'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'Password': 'new-secret'}),
        ),
      );

      expect(pluginService.savedPatch, {'Password': 'new-secret'});
      expect(response.statusCode, 200);
      final body = await response.readAsString();
      expect(body, isNot(contains('new-secret')));
      expect(jsonDecode(body), {
        'Username': 'user',
        'Password': {'isSet': true},
      });
    });

    test('POST passes null clears through to the service unchanged', () async {
      final response = await app.call(
        Request(
          'POST',
          Uri.parse('http://localhost/api/v1/plugins/$pluginId/settings'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'Username': 'new-user', 'Password': null}),
        ),
      );

      expect(pluginService.savedPatch, {
        'Username': 'new-user',
        'Password': null,
      });
      expect(response.statusCode, 200);
    });

    test(
      'POST delegates the reload to the service instead of reloading',
      () async {
        final response = await app.call(
          Request(
            'POST',
            Uri.parse('http://localhost/api/v1/plugins/$pluginId/settings'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'Username': 'new-user'}),
          ),
        );

        expect(response.statusCode, 200);
        expect(pluginService.savedPatch, {'Username': 'new-user'});
        expect(
          pluginService.reloadCalls,
          0,
          reason:
              'apply-on-save lives in savePluginSettings; the handler '
              'must not reload as well',
        );
      },
    );
  });

  test('synchronous plugin response completes the request directly', () async {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      pluginHttpTimeout: const Duration(seconds: 5),
    );
    addTearDown(manager.cancelAllOperations);
    await manager.loadPlugin(
      id: pluginId,
      manifest: httpManifest(),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$pluginId",
            handleHttpRequest: (request) => ({
              status: 200,
              headers: {'Content-Type': 'application/json'},
              body: JSON.stringify({echo: request.body})
            })
          };
        }
      ''',
    );
    final app = Router().plus;
    PluginsHandler(
      pluginManager: manager,
      pluginService: _FakePluginLoaderService(),
    ).addRoutes(app);

    final response = await app.call(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/plugins/$pluginId/hello'),
      ),
    );

    expect(response.statusCode, 200);
    expect(await response.readAsString(), '{"echo":null}');
    expect(manager.activePendingOpCount, 0);
  });

  test('HTTP plugin endpoint rejects missing api permission', () async {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      pluginHttpTimeout: const Duration(seconds: 5),
    );
    addTearDown(manager.cancelAllOperations);
    await manager.loadPlugin(
      id: pluginId,
      manifest: httpManifest(permissions: const {}),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$pluginId",
            handleHttpRequest: () => ({status: 200, headers: {}, body: "no"})
          };
        }
      ''',
    );
    final app = Router().plus;
    PluginsHandler(
      pluginManager: manager,
      pluginService: _FakePluginLoaderService(),
    ).addRoutes(app);

    final response = await app.call(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/plugins/$pluginId/hello'),
      ),
    );

    expect(response.statusCode, 403);
    expect(await response.readAsString(), contains('api'));
    expect(manager.activePendingOpCount, 0);
  });

  test('asynchronous plugin response completes the request directly', () async {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      pluginHttpTimeout: const Duration(seconds: 5),
    );
    addTearDown(manager.cancelAllOperations);
    await manager.loadPlugin(
      id: pluginId,
      manifest: httpManifest(),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$pluginId",
            handleHttpRequest: async (request) => {
              await new Promise(r => setTimeout(r, 30));
              return { status: 200, headers: {}, body: "async-response" };
            }
          };
        }
      ''',
    );
    final app = Router().plus;
    PluginsHandler(
      pluginManager: manager,
      pluginService: _FakePluginLoaderService(),
    ).addRoutes(app);

    final response = await app.call(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/plugins/$pluginId/hello'),
      ),
    );

    expect(response.statusCode, 200);
    expect(await response.readAsString(), 'async-response');
    expect(manager.activePendingOpCount, 0);
  });

  test('throwing plugin handler returns a 500 error response', () async {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      pluginHttpTimeout: const Duration(seconds: 5),
    );
    addTearDown(manager.cancelAllOperations);
    await manager.loadPlugin(
      id: pluginId,
      manifest: httpManifest(),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$pluginId",
            handleHttpRequest: () => { throw new Error("boom"); }
          };
        }
      ''',
    );
    final app = Router().plus;
    PluginsHandler(
      pluginManager: manager,
      pluginService: _FakePluginLoaderService(),
    ).addRoutes(app);

    final response = await app.call(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/plugins/$pluginId/hello'),
      ),
    );

    expect(response.statusCode, 500);
    expect(manager.activePendingOpCount, 0);
  });

  test(
    'timeout returns a clean error and removes the registry entry',
    () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        pluginHttpTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(manager.cancelAllOperations);
      await manager.loadPlugin(
        id: pluginId,
        manifest: httpManifest(),
        settings: {},
        jsCode:
            '''
        function createPlugin(host) {
          return { id: "$pluginId" };
        }
      ''',
      );
      final app = Router().plus;
      PluginsHandler(
        pluginManager: manager,
        pluginService: _FakePluginLoaderService(),
      ).addRoutes(app);

      final response = await app.call(
        Request(
          'GET',
          Uri.parse('http://localhost/api/v1/plugins/$pluginId/hello'),
        ),
      );

      expect(response.statusCode, 500);
      expect(
        await response.readAsString(),
        contains('did not respond in time'),
      );
      expect(manager.activePendingOpCount, 0);
    },
  );

  test('response arriving after timeout is ignored and not retained', () async {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      pluginHttpTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(manager.cancelAllOperations);
    await manager.loadPlugin(
      id: pluginId,
      manifest: httpManifest(),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$pluginId",
            handleHttpRequest: (request) => new Promise((resolve) => {
              setTimeout(() => resolve({
                status: 200, headers: {}, body: "late-response"
              }), 400);
            })
          };
        }
      ''',
    );
    final app = Router().plus;
    PluginsHandler(
      pluginManager: manager,
      pluginService: _FakePluginLoaderService(),
    ).addRoutes(app);

    final response = await app.call(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/plugins/$pluginId/hello'),
      ),
    );
    expect(await response.readAsString(), contains('did not respond in time'));

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(manager.activePendingOpCount, 0);
  });

  test('plugin unload completes pending HTTP requests with an error', () async {
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      pluginHttpTimeout: const Duration(seconds: 5),
    );
    addTearDown(manager.cancelAllOperations);
    await manager.loadPlugin(
      id: pluginId,
      manifest: httpManifest(),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$pluginId",
            handleHttpRequest: (request) => new Promise((resolve) => {
              setTimeout(() => resolve({ status: 200, headers: {}, body: "never" }), 5000);
            })
          };
        }
      ''',
    );
    final app = Router().plus;
    PluginsHandler(
      pluginManager: manager,
      pluginService: _FakePluginLoaderService(),
    ).addRoutes(app);

    final responseFuture = app.call(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/plugins/$pluginId/hello'),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await manager.unloadPlugin(pluginId);

    final response = await responseFuture;
    expect(await response.readAsString(), contains('unloaded'));
    expect(manager.activePendingOpCount, 0);
  });
}
