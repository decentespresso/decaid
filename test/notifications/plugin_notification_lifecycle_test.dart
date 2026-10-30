import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugins/plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late NotificationCenter center;
  late PluginLoaderService loader;
  late SharedPreferences preferences;

  Future<void> retain(String source) => center.publish(
    NativeNotification(
      namespace: NotificationNamespace.plugin,
      sourceId: source,
      sourceName: source,
      id: 'condition',
      message: 'Needs attention',
    ),
  );

  Future<void> updateSource({
    required bool permission,
    bool fail = false,
  }) => loader
      .updatePluginSource(
        'first',
        manifestJson: {
          'id': 'first',
          'name': 'First',
          'author': 'Test',
          'description': 'Test',
          'version': '1.0.0',
          'apiVersion': 1,
          'permissions': [if (permission) 'notifications'],
          'settings': <String, Object>{},
          'api': <Object>[],
        },
        pluginJs:
            'function createPlugin() { return {id: "first", onLoad() { ${fail ? 'throw new Error("load failed");' : ''} }}; }',
      )
      .then((_) {});

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('notification-lifecycle');
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    center = NotificationCenter(preferences: preferences);
    loader = PluginLoaderService(
      kvStore: FakeKeyValueStoreService(),
      notifications: center,
    );
    await loader.initialize();
    await retain('first');
    await retain('second');
  });

  tearDown(() async {
    await loader.dispose();
    center.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await directory.delete(recursive: true);
  });

  for (final operation in ['unload', 'disable', 'uninstall']) {
    test(
      '$operation removes retained notices even without a running generation',
      () async {
        switch (operation) {
          case 'unload':
            await loader.unloadPlugin('first');
          case 'disable':
            await loader.disablePlugin('first');
          case 'uninstall':
            await loader.removePlugin('first');
        }
        expect(center.value.single.sourceId, 'second');
        final restored = NotificationCenter(preferences: preferences);
        addTearDown(restored.dispose);
        expect(restored.value.single.sourceId, 'second');
      },
    );
  }

  test(
    'app shutdown retains notices and their read state for reconstruction',
    () async {
      await center.markRead(center.value);
      await loader.dispose();
      final restored = NotificationCenter(preferences: preferences);
      addTearDown(restored.dispose);
      expect(restored.value.map((notice) => notice.sourceId), [
        'first',
        'second',
      ]);
      expect(restored.unreadCount, 0);
      expect(
        restored.value.every((notice) => !restored.isConfirmed(notice)),
        isTrue,
      );
    },
  );

  test(
    'permission removal from an unloaded source removes retained notices',
    () async {
      await updateSource(permission: true);
      await updateSource(permission: false);
      expect(center.value.single.sourceId, 'second');
    },
  );

  test(
    'a failed permission-changing reload preserves the previous saved notice',
    () async {
      await updateSource(permission: true);
      await loader.enablePlugin('first');
      await center.markRead(center.value);
      await expectLater(
        updateSource(permission: false, fail: true),
        throwsException,
      );
      expect(center.value.map((notice) => notice.sourceId), [
        'first',
        'second',
      ]);
      expect(center.unreadCount, 0);
      expect(loader.isPluginLoaded('first'), isTrue);
    },
  );
}
