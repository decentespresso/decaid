import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

void main() {
  late PluginManager manager;

  setUp(() => manager = PluginManager(kvStore: FakeKeyValueStoreService()));
  tearDown(() => manager.dispose());

  Future<void> load(
    String id, {
    bool allowed = true,
    String onLoad = '',
  }) async {
    await manager.loadPlugin(
      id: id,
      manifest: testManifest(
        id,
        permissions: {
          PluginPermissions.emit,
          if (allowed) PluginPermissions.notifications,
        },
      ),
      settings: {},
      jsCode:
          '''
        function createPlugin(host) {
          return {
            id: '$id',
            onLoad() { $onLoad },
            onEvent(event) {
              if (event.name === 'notificationAction') host.emit('action', event.payload);
              if (event.name === 'notificationDismissed') host.emit('dismissed', event.payload);
            }
          };
        }
      ''',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  const notice = '''{
    id: 'condition', message: 'Attention',
    action: {id: 'help', type: 'openExternalUrl', label: 'Help', url: 'https://example.com/'}
  }''';

  test(
    'notification permission is recognized and enforced in JavaScript',
    () async {
      expect(
        PluginPermissions.fromString('notifications'),
        PluginPermissions.notifications,
      );
      await load('first', onLoad: 'host.notify($notice);');
      expect(manager.notifications.value.single.pluginId, 'first');
      await expectLater(
        load('denied', allowed: false, onLoad: 'host.notify($notice);'),
        throwsA(
          predicate((error) => error.toString().contains('notifications')),
        ),
      );
      expect(manager.notifications.value.length, 1);
    },
  );

  test(
    'raw bridge cannot bypass permission checks or spoof another owner',
    () async {
      await load('first', onLoad: 'host.notify($notice);');
      await load(
        'denied',
        allowed: false,
        onLoad:
            '''
      pluginHostBridge.notify(pluginBridgeToken, pluginGeneration, $notice);
      globalThis.host.notify('first', pluginGeneration, $notice);
    ''',
      );
      expect(manager.notifications.value.single.pluginId, 'first');
    },
  );

  test('dismiss and unload cannot clear another plugin notification', () async {
    final events = <Map<String, dynamic>>[];
    final subscription = manager.emitStream.listen(events.add);
    addTearDown(subscription.cancel);
    await load('first', onLoad: 'host.notify($notice);');
    await load(
      'second',
      onLoad: 'host.notify($notice); host.dismissNotification("condition");',
    );
    expect(manager.notifications.value.single.pluginId, 'first');
    await load('second', onLoad: 'host.notify($notice);');
    await manager.unloadPlugin('first');
    expect(manager.notifications.value.single.pluginId, 'second');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events, isEmpty);
  });

  test(
    'user dismissal is targeted and retired notices cannot dismiss a replacement',
    () async {
      final events = <Map<String, dynamic>>[];
      final subscription = manager.emitStream.listen(events.add);
      addTearDown(subscription.cancel);
      await load('first', onLoad: 'host.notify($notice);');
      await load('second', onLoad: 'host.notify($notice);');
      final old = manager.notifications.value.first;
      manager.notifications.dismissByUser(old);
      manager.notifications.dismissByUser(old);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.single, {
        'pluginId': 'first',
        'event': 'dismissed',
        'payload': {'id': 'condition'},
      });
      await manager.unloadPlugin('first');
      await load('first', onLoad: 'host.notify($notice);');
      manager.notifications.dismissByUser(old);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.length, 1);
      expect(manager.notifications.value.map((notice) => notice.pluginId), [
        'second',
        'first',
      ]);
    },
  );

  test('dismissal events require notification permission', () async {
    final events = <Map<String, dynamic>>[];
    final subscription = manager.emitStream.listen(events.add);
    addTearDown(subscription.cancel);
    await load('denied', allowed: false);
    manager.dispatchEvent('denied', 'notificationDismissed', {
      'id': 'condition',
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events, isEmpty);
  });

  test(
    'action routing is targeted and rejects retired plugin generations',
    () async {
      final events = <Map<String, dynamic>>[];
      final subscription = manager.emitStream.listen(events.add);
      addTearDown(subscription.cancel);
      await load('first', onLoad: 'host.notify($notice);');
      await load('second', onLoad: 'host.notify($notice);');
      final old = manager.notifications.value.first;
      old.reportAction('activated');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.single['pluginId'], 'first');
      expect(jsonEncode(events.single['payload']), contains('activated'));
      await manager.unloadPlugin('first');
      await load('first', onLoad: 'host.notify($notice);');
      old.reportAction('returned');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.length, 1);
    },
  );
}
