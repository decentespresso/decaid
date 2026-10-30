import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/notifications/notification_center.dart';

import 'plugin_test_helpers.dart';

void main() {
  late PluginManager manager;

  setUp(() => manager = PluginManager(kvStore: FakeKeyValueStoreService()));
  tearDown(() => manager.dispose());

  Future<void> load(
    String id, {
    bool allowed = true,
    String onLoad = '',
    bool reportResults = false,
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
              if (event.name === 'notificationResult' && $reportResults) host.emit('result', event.payload);
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
      expect(manager.notifications.value.single.sourceId, 'first');
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
      expect(manager.notifications.value.single.sourceId, 'first');
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
    expect(manager.notifications.value.single.sourceId, 'first');
    await load('second', onLoad: 'host.notify($notice);');
    await manager.unloadPlugin('first');
    expect(manager.notifications.value.single.sourceId, 'second');
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
      await manager.notifications.dismissByUser(old);
      await manager.notifications.dismissByUser(old);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.single, {
        'pluginId': 'first',
        'event': 'dismissed',
        'payload': {'id': 'condition'},
      });
      await manager.unloadPlugin('first');
      await load('first', onLoad: 'host.notify($notice);');
      await manager.notifications.dismissByUser(old);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.length, 1);
      expect(manager.notifications.value.map((notice) => notice.sourceId), [
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
      final activation = manager.notifications.activation(old);
      manager.notifications.reportAction(
        activation,
        old.actions.single,
        'activated',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.single['pluginId'], 'first');
      expect(jsonEncode(events.single['payload']), contains('activated'));
      await manager.unloadPlugin('first');
      await load('first', onLoad: 'host.notify($notice);');
      manager.notifications.reportAction(
        activation,
        old.actions.single,
        'returned',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events.length, 1);
    },
  );

  test(
    'notify returns a request ID and targeted durable delivery results',
    () async {
      final events = <Map<String, dynamic>>[];
      final subscription = manager.emitStream.listen(events.add);
      addTearDown(subscription.cancel);
      await load('other', reportResults: true);
      await load(
        'first',
        reportResults: true,
        onLoad: 'globalThis.noticeRequest = host.notify($notice);',
      );
      expect(events.single['pluginId'], 'first');
      final result = events.single['payload'] as Map;
      expect(
        result['requestId'],
        manager.js.evaluate('globalThis.noticeRequest').stringResult,
      );
      expect(result['id'], 'condition');
      expect(result['status'], 'accepted');
      expect(manager.notifications.unreadCount, 1);
    },
  );

  test(
    'validation and capacity rejections are explicit and targeted',
    () async {
      final events = <Map<String, dynamic>>[];
      final subscription = manager.emitStream.listen(events.add);
      addTearDown(subscription.cancel);
      await load(
        'first',
        reportResults: true,
        onLoad: '''
      host.notify({id: 'valid-id', message: ''});
      for (let i = 0; i < 6; i++) host.notify({id: String(i), message: 'Attention'});
    ''',
      );
      final results = events.map((event) => event['payload'] as Map).toList();
      expect(results.first['reason'], 'validation');
      expect(results.first['id'], 'valid-id');
      expect(results.last['reason'], 'capacity');
      expect(
        results.where((result) => result['status'] == 'accepted'),
        hasLength(5),
      );
      expect(events.every((event) => event['pluginId'] == 'first'), isTrue);
    },
  );

  test('storage rejection never reports acceptance', () async {
    await manager.dispose();
    final center = NotificationCenter(save: (_) async => false);
    manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      notifications: center,
    );
    final events = <Map<String, dynamic>>[];
    final subscription = manager.emitStream.listen(events.add);
    addTearDown(subscription.cancel);
    await load('first', reportResults: true, onLoad: 'host.notify($notice);');
    expect((events.single['payload'] as Map)['reason'], 'storage');
    expect(center.value, isEmpty);
  });

  test(
    'runtime shutdown and reload retain notices while explicit unload removes them',
    () async {
      await load('first', onLoad: 'host.notify($notice);');
      await manager.notifications.markRead(manager.notifications.value);
      final old = manager.notifications.activation(
        manager.notifications.value.single,
      );
      await load('first');
      expect(manager.notifications.value, hasLength(1));
      expect(
        manager.notifications.isConfirmed(manager.notifications.value.single),
        isFalse,
      );
      expect(manager.notifications.isCurrent(old), isFalse);
      await load('first', onLoad: 'host.notify($notice);');
      expect(manager.notifications.unreadCount, 0);
      expect(
        manager.notifications.isConfirmed(manager.notifications.value.single),
        isTrue,
      );
      await manager.dispose();
      expect(manager.notifications.value, hasLength(1));
      expect(
        manager.notifications.isConfirmed(manager.notifications.value.single),
        isFalse,
      );
    },
  );
}
