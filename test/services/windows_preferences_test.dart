import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:reaprime/src/services/storage/windows_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

class _Paths extends PathProviderWindows {
  _Paths(this.path, {this.available});
  final String path;
  final bool Function()? available;

  @override
  Future<String?> getApplicationSupportPath() async =>
      available?.call() == false ? null : path;
}

class _FailedWrites extends SharedPreferencesWindows {
  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async => {};

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async => false;
}

class _PausedFailure extends SharedPreferencesWindows {
  final failed = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final saved = await super.setValue(valueType, key, value);
    if (!saved && !failed.isCompleted) {
      failed.complete();
      await resume.future;
    }
    return saved;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('interleaved legacy notifications and Async settings survive disk reconstruction', () async {
    final directory = await Directory.systemTemp.createTemp(
      'decaid-preferences-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final originalLegacy = SharedPreferencesStorePlatform.instance;
    final originalAsync = SharedPreferencesAsyncPlatform.instance;
    addTearDown(() {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = originalLegacy;
      SharedPreferencesAsyncPlatform.instance = originalAsync;
    });
    final file = File('${directory.path}/shared_preferences.json');
    await file.writeAsString(
      jsonEncode({
        'themeMode': 'dark',
        'flutter.plugin.settings.test': 'existing',
      }),
    );
    Future<void> restart() async {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
        ..pathProvider = _Paths(directory.path);
      SharedPreferencesAsyncPlatform.instance = SharedPreferencesAsyncWindows()
        ..pathProvider = _Paths(directory.path);
      await initializeWindowsPreferences();
    }

    await restart();
    final settings = SharedPreferencesAsync();
    final legacy = await SharedPreferences.getInstance();
    final center = NotificationCenter(preferences: legacy);
    addTearDown(center.dispose);
    expect(await settings.getString('themeMode'), 'dark');
    expect(legacy.getString('plugin.settings.test'), 'existing');
    await center.publish(
      NativeNotification(
        namespace: NotificationNamespace.plugin,
        sourceId: 'test',
        sourceName: 'Test',
        id: 'pause',
        message: 'Paused',
      ),
    );
    await settings.setString('skippedVersion', '99.0.0');
    await center.markRead(center.value);
    await legacy.setBool('plugin.enabled.test', true);
    await settings.setString('themeMode', 'light');
    await settings.setBool('enabled', true);
    await settings.setDouble('ratio', 1.25);
    await settings.setStringList('list', ['one', 'two']);
    await Future.wait([
      settings.setInt('counter', 7),
      legacy.setString('plugin.settings.test', 'changed'),
    ]);
    await restart();
    final restoredSettings = SharedPreferencesAsync();
    final restoredLegacy = await SharedPreferences.getInstance();
    final restored = NotificationCenter(preferences: restoredLegacy);
    addTearDown(restored.dispose);
    expect(restored.value.single.message, 'Paused');
    expect(restored.unreadCount, 0);
    expect(await restoredSettings.getString('skippedVersion'), '99.0.0');
    expect(await restoredSettings.getString('themeMode'), 'light');
    expect(await restoredSettings.getInt('counter'), 7);
    expect(await restoredSettings.getBool('enabled'), isTrue);
    expect(await restoredSettings.getDouble('ratio'), 1.25);
    expect(await restoredSettings.getStringList('list'), ['one', 'two']);
    expect(await restoredSettings.getKeys(allowList: {'ratio', 'missing'}), {
      'ratio',
    });
    expect(restoredLegacy.getString('plugin.settings.test'), 'changed');
    expect(restoredLegacy.getBool('plugin.enabled.test'), isTrue);
    await restoredSettings.remove('skippedVersion');
    await restoredLegacy.setString('anotherPluginSetting', 'kept');
    final disk = jsonDecode(await file.readAsString()) as Map;
    expect(disk.containsKey('skippedVersion'), isFalse);
    expect(disk['flutter.${NotificationCenter.storageKey}'], isNotNull);
    expect(disk['flutter.anotherPluginSetting'], 'kept');
  });

  for (final operation in ['publication', 'read', 'resolution']) {
    test(
      'failed notification $operation is not persisted by later settings writes',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'decaid-preferences-rollback-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final originalLegacy = SharedPreferencesStorePlatform.instance;
        final originalAsync = SharedPreferencesAsyncPlatform.instance;
        addTearDown(() {
          SharedPreferences.resetStatic();
          SharedPreferencesStorePlatform.instance = originalLegacy;
          SharedPreferencesAsyncPlatform.instance = originalAsync;
        });
        var writesAvailable = true;
        Future<SharedPreferences> restart() async {
          SharedPreferences.resetStatic();
          SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
            ..pathProvider = _Paths(
              directory.path,
              available: () => writesAvailable,
            );
          await initializeWindowsPreferences();
          return SharedPreferences.getInstance();
        }

        final legacy = await restart();
        final center = NotificationCenter(preferences: legacy);
        addTearDown(center.dispose);
        final notice = NativeNotification(
          namespace: NotificationNamespace.plugin,
          sourceId: 'test',
          sourceName: 'Test',
          id: 'pause',
          message: 'Paused',
        );
        if (operation != 'publication') await center.publish(notice);
        final previous = legacy.getString(NotificationCenter.storageKey);
        writesAvailable = false;
        await expectLater(switch (operation) {
          'publication' => center.publish(notice),
          'read' => center.markRead(center.value),
          _ => center.removeSource(NotificationNamespace.plugin, 'test'),
        }, throwsA(isA<NotificationStorageException>()));
        writesAvailable = true;
        await SharedPreferencesAsync().setString('themeMode', 'dark');
        final restoredLegacy = await restart();
        final restored = NotificationCenter(preferences: restoredLegacy);
        addTearDown(restored.dispose);
        expect(
          restoredLegacy.getString(NotificationCenter.storageKey),
          previous,
        );
        expect(restored.value, hasLength(operation == 'publication' ? 0 : 1));
        expect(restored.unreadCount, operation == 'publication' ? 0 : 1);
        expect(await SharedPreferencesAsync().getString('themeMode'), 'dark');
      },
    );
  }

  test(
    'settings writes wait for a failed notification cache rollback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'decaid-preferences-concurrent-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final originalLegacy = SharedPreferencesStorePlatform.instance;
      final originalAsync = SharedPreferencesAsyncPlatform.instance;
      addTearDown(() {
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = originalLegacy;
        SharedPreferencesAsyncPlatform.instance = originalAsync;
      });
      var writesAvailable = false;
      final backend = _PausedFailure()
        ..pathProvider = _Paths(
          directory.path,
          available: () => writesAvailable,
        );
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = backend;
      await initializeWindowsPreferences();
      final legacy = await SharedPreferences.getInstance();
      final center = NotificationCenter(preferences: legacy);
      addTearDown(center.dispose);
      final failedSave = expectLater(
        center.publish(
          NativeNotification(
            namespace: NotificationNamespace.plugin,
            sourceId: 'test',
            sourceName: 'Test',
            id: 'pause',
            message: 'Paused',
          ),
        ),
        throwsA(isA<NotificationStorageException>()),
      );
      await backend.failed.future;
      writesAvailable = true;
      var settingsSaved = false;
      final settingsWrite = SharedPreferencesAsync()
          .setString('themeMode', 'dark')
          .then((_) => settingsSaved = true);
      await Future<void>.delayed(Duration.zero);
      final remainedQueued = !settingsSaved;
      backend.resume.complete();
      await failedSave;
      await settingsWrite;
      expect(remainedQueued, isTrue);
      final disk = jsonDecode(
        await File('${directory.path}/shared_preferences.json').readAsString(),
      ) as Map;
      expect(disk['flutter.${NotificationCenter.storageKey}'], isNull);
      expect(disk['themeMode'], 'dark');
      expect(legacy.getString(NotificationCenter.storageKey), isNull);
    },
  );

  for (final operation in ['set', 'remove', 'clear']) {
    test(
      'failed Async $operation restores only affected preferences',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'decaid-preferences-async-rollback-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final originalLegacy = SharedPreferencesStorePlatform.instance;
        final originalAsync = SharedPreferencesAsyncPlatform.instance;
        addTearDown(() {
          SharedPreferences.resetStatic();
          SharedPreferencesStorePlatform.instance = originalLegacy;
          SharedPreferencesAsyncPlatform.instance = originalAsync;
        });
        var writesAvailable = true;
        Future<SharedPreferences> restart() async {
          SharedPreferences.resetStatic();
          SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
            ..pathProvider = _Paths(
              directory.path,
              available: () => writesAvailable,
            );
          await initializeWindowsPreferences();
          return SharedPreferences.getInstance();
        }

        final legacy = await restart();
        final settings = SharedPreferencesAsync();
        await settings.setString('target', 'before');
        await settings.setStringList('another', ['one', 'two']);
        await legacy.setBool('enabled', true);
        writesAvailable = false;
        await expectLater(switch (operation) {
          'set' => settings.setString('target', 'after'),
          'remove' => settings.remove('target'),
          _ => settings.clear(allowList: {'target', 'another'}),
        }, throwsStateError);
        writesAvailable = true;
        await legacy.setBool('enabled', false);
        final restoredLegacy = await restart();
        final restoredSettings = SharedPreferencesAsync();
        expect(await restoredSettings.getString('target'), 'before');
        expect(await restoredSettings.getStringList('another'), ['one', 'two']);
        expect(restoredLegacy.getBool('enabled'), isFalse);
      },
    );
  }

  test('failed backend writes and removals reject Async operations', () async {
    final originalLegacy = SharedPreferencesStorePlatform.instance;
    final originalAsync = SharedPreferencesAsyncPlatform.instance;
    addTearDown(() {
      SharedPreferencesStorePlatform.instance = originalLegacy;
      SharedPreferencesAsyncPlatform.instance = originalAsync;
    });
    SharedPreferencesStorePlatform.instance = _FailedWrites();
    await initializeWindowsPreferences();
    final settings = SharedPreferencesAsync();
    await expectLater(
      settings.setString('skippedVersion', '99.0.0'),
      throwsStateError,
    );
    await expectLater(settings.remove('skippedVersion'), throwsStateError);
  });
}
