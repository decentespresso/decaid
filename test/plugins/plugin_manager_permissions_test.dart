import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

void main() {
  const pluginId = 'permissions.plugin';

  late FakeKeyValueStoreService store;
  late PluginManager manager;

  setUp(() {
    store = FakeKeyValueStoreService();
    manager = PluginManager(kvStore: store);
  });

  tearDown(() {
    manager.cancelAllOperations();
  });

  Future<void> load(
    Set<PluginPermissions> permissions,
    String onLoad, {
    String onEvent = '',
  }) {
    return manager.loadPlugin(
      id: pluginId,
      manifest: testManifest(pluginId, permissions: permissions),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$pluginId",
            onLoad() { $onLoad },
            onEvent(event) { $onEvent }
          };
        }
      ''',
    );
  }

  Matcher permissionError(String permission) => throwsA(
    predicate(
      (error) =>
          error.toString().contains('requires manifest permission') &&
          error.toString().contains(permission),
    ),
  );

  test('host.log allows declared permission and rejects omission', () async {
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      Logger.root.level = previousLevel;
      await subscription.cancel();
    });

    await load({PluginPermissions.log}, 'host.log("allowed");');

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      records.any(
        (record) => record.message.contains('[JS:$pluginId] allowed'),
      ),
      isTrue,
    );

    await expectLater(
      load(const {}, 'host.log("denied");'),
      permissionError('log'),
    );
  });

  test('host.emit allows declared permission and rejects omission', () async {
    final event = manager.emitStream.first;

    await load({PluginPermissions.emit}, 'host.emit("allowed", 1);');

    expect((await event)['event'], 'allowed');

    await expectLater(
      load(const {}, 'host.emit("denied", 1);'),
      permissionError('emit'),
    );
  });

  test(
    'host.storage allows declared permission and rejects omission',
    () async {
      await load({
        PluginPermissions.pluginStorage,
      }, 'host.storage({type: "write", key: "allowed", data: "yes"});');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await store.get(namespace: pluginId, key: 'allowed'), 'yes');

      await expectLater(
        load(
          const {},
          'host.storage({type: "write", key: "denied", data: "no"});',
        ),
        permissionError('pluginStorage'),
      );
    },
  );

  test('Dart rejects direct bridge calls without permissions', () async {
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    final events = <Map<String, dynamic>>[];
    final eventSubscription = manager.emitStream.listen(events.add);
    addTearDown(() async {
      Logger.root.level = previousLevel;
      await subscription.cancel();
      await eventSubscription.cancel();
    });

    await load(const {}, '''
      globalThis.__reaprimePluginHostBridge.log(pluginBridgeToken, "bypass");
      globalThis.__reaprimePluginHostBridge.emit(
        pluginBridgeToken, "bypass", null
      );
      globalThis.__reaprimePluginHostBridge.storage(pluginBridgeToken, {
        type: "write", key: "bypass", data: "no"
      });
    ''');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(events, isEmpty);
    expect(await store.get(namespace: pluginId, key: 'bypass'), isNull);
    for (final permission in ['log', 'emit', 'pluginStorage']) {
      expect(
        records.any(
          (record) =>
              record.message.contains(pluginId) &&
              record.message.contains(permission),
        ),
        isTrue,
      );
    }
  });

  test(
    'raw bridge cannot borrow another plugin permission or storage',
    () async {
      const privilegedPluginId = 'privileged.plugin';
      final events = <Map<String, dynamic>>[];
      final subscription = manager.emitStream.listen(events.add);
      addTearDown(subscription.cancel);

      await manager.loadPlugin(
        id: privilegedPluginId,
        manifest: testManifest(
          privilegedPluginId,
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.pluginStorage,
          },
        ),
        settings: {},
        jsCode:
            '''
        function createPlugin(host) {
          return { id: "$privilegedPluginId" };
        }
      ''',
      );

      await load(const {}, '''
      globalThis.host.emit("$privilegedPluginId", "spoofed", "payload");
      globalThis.host.storage("$privilegedPluginId", {
        type: "write", key: "spoofed", data: "payload"
      });
    ''');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events, isEmpty);
      expect(
        await store.get(namespace: privilegedPluginId, key: 'spoofed'),
        isNull,
      );
    },
  );

  test('timer debug state cannot expose another plugin token', () async {
    const privilegedPluginId = 'privileged.timer.plugin';
    final events = <Map<String, dynamic>>[];
    final subscription = manager.emitStream.listen(events.add);
    addTearDown(subscription.cancel);

    await manager.loadPlugin(
      id: privilegedPluginId,
      manifest: testManifest(
        privilegedPluginId,
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.pluginStorage,
        },
      ),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: "$privilegedPluginId",
            onLoad() { setTimeout(() => {}, 60000); }
          };
        }
      ''',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(manager.activeTimerCount, 1);

    await load(const {}, '''
      const timers = globalThis.__debugTimers;
      if (timers) {
        const victim = [...timers.values()][0];
        globalThis.host.emit(victim.bridgeToken, "spoofed", "payload");
        globalThis.host.storage(victim.bridgeToken, {
          type: "write", key: "spoofed", data: "payload"
        });
      }
    ''');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(events, isEmpty);
    expect(
      await store.get(namespace: privilegedPluginId, key: 'spoofed'),
      isNull,
    );
  });

  test('timer cleanup cannot expose another plugin token', () async {
    const privilegedPluginId = 'privileged.unload.plugin';
    final events = <Map<String, dynamic>>[];
    final subscription = manager.emitStream.listen(events.add);
    addTearDown(subscription.cancel);

    await manager.loadPlugin(
      id: privilegedPluginId,
      manifest: testManifest(
        privilegedPluginId,
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.pluginStorage,
        },
      ),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return { id: "$privilegedPluginId" };
        }
      ''',
    );

    await load(const {}, '''
      globalThis.__cancelTimersForBridgeToken = function(bridgeToken) {
        globalThis.host.emit(bridgeToken, "spoofed", "payload");
        globalThis.host.storage(bridgeToken, {
          type: "write", key: "spoofed", data: "payload"
        });
      };
    ''');

    await manager.unloadPlugin(privilegedPluginId);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(events, isEmpty);
    expect(
      await store.get(namespace: privilegedPluginId, key: 'spoofed'),
      isNull,
    );
  });

  test('host.decentProxy rejects with PluginPermissionError', () async {
    final event = manager.emitStream.first;

    await load(
      {PluginPermissions.emit},
      '''
      host.decentProxy("support/api/sn")
        .catch((error) => host.emit("error", error.name + ":" + error.message));
    ''',
    );

    expect((await event)['payload'], contains('PluginPermissionError'));
  });

  test('host.decentProxy POST requires write permission', () async {
    final event = manager.emitStream.first;

    await load(
      {PluginPermissions.emit, PluginPermissions.proxyDecentApi},
      '''
      host.decentProxy("support/api/shot_upload", {method: "POST"})
        .catch((error) => host.emit("error", error.name + ":" + error.message));
    ''',
    );

    expect((await event)['payload'], contains('proxy.decent_api.write'));
  });

  test('timers require no manifest permission', () async {
    await load(
      const {},
      'setTimeout(() => globalThis.__timerFired = true, 0);',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      manager.js.evaluate('String(globalThis.__timerFired)').stringResult,
      'true',
    );
  });

  test('stateUpdate requires events.machine', () async {
    await load(
      {PluginPermissions.eventsMachine},
      '',
      onEvent: 'globalThis.__eventCount = (globalThis.__eventCount || 0) + 1;',
    );

    manager.dispatchEvent(pluginId, 'stateUpdate', const {});

    expect(
      manager.js.evaluate('String(globalThis.__eventCount)').stringResult,
      '1',
    );
  });

  test('stateUpdate is withheld without events.machine', () async {
    await load(
      const {},
      '',
      onEvent: 'globalThis.__eventCount = (globalThis.__eventCount || 0) + 1;',
    );

    manager.dispatchEvent(pluginId, 'stateUpdate', const {});

    expect(
      manager.js.evaluate('String(globalThis.__eventCount || 0)').stringResult,
      '0',
    );
  });

  test('shot events require events.shots', () async {
    await load(
      {PluginPermissions.eventsShots},
      '',
      onEvent: 'globalThis.__eventCount = (globalThis.__eventCount || 0) + 1;',
    );

    manager.dispatchEvent(pluginId, 'shotStored', const {});
    manager.dispatchEvent(pluginId, 'shotUpdated', const {});

    expect(
      manager.js.evaluate('String(globalThis.__eventCount)').stringResult,
      '2',
    );
  });

  test('shot events are withheld without events.shots', () async {
    await load(
      const {},
      '',
      onEvent: 'globalThis.__eventCount = (globalThis.__eventCount || 0) + 1;',
    );

    manager.dispatchEvent(pluginId, 'shotStored', const {});
    manager.dispatchEvent(pluginId, 'shotUpdated', const {});

    expect(
      manager.js.evaluate('String(globalThis.__eventCount || 0)').stringResult,
      '0',
    );
  });
}
