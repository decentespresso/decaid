import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/notifications/update_notifications.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mock_settings_service.dart';

class _Updater extends AndroidUpdater {
  _Updater() : super(owner: 'unused', repo: 'unused');

  bool fail = false;
  UpdateInfo? next;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    if (fail) throw StateError('Offline');
    return next;
  }
}

void main() {
  late SharedPreferences preferences;
  late NotificationCenter center;
  late UpdateCheckService service;
  late UpdateNotifications updates;
  late MockSettingsService settings;
  late _Updater updater;
  final downloads = <String>[];

  UpdateInfo update(String version) => UpdateInfo(
    version: version,
    downloadUrl: 'https://example.com/app.apk',
    releaseNotes: 'Changes',
    isPrerelease: false,
    tagName: 'v$version',
  );

  Future<void> restart({bool failSave = false}) async {
    await updates.dispose();
    service.dispose();
    center.dispose();
    center = NotificationCenter(
      preferences: preferences,
      save: failSave ? (_) async => false : null,
    );
    updater = _Updater();
    service = UpdateCheckService(
      settingsService: settings,
      webUIStorage: WebUIStorage(SettingsController(settings)),
      updater: updater,
      platformIsAndroid: true,
      platformIsMacOS: false,
      externallyManaged: false,
    );
    updates = UpdateNotifications(
      center: center,
      service: service,
      onDownload: (info) async => downloads.add(info.version),
    );
    await updates.settled;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    center = NotificationCenter(preferences: preferences);
    settings = MockSettingsService();
    updater = _Updater();
    service = UpdateCheckService(
      settingsService: settings,
      webUIStorage: WebUIStorage(SettingsController(settings)),
      updater: updater,
      platformIsAndroid: true,
      platformIsMacOS: false,
      externallyManaged: false,
    );
    downloads.clear();
    updates = UpdateNotifications(
      center: center,
      service: service,
      onDownload: (info) async => downloads.add(info.version),
    );
    await updates.settled;
  });

  tearDown(() async {
    await updates.dispose();
    service.dispose();
    center.dispose();
  });

  test(
    'repeated checks retain read state and bind trusted actions to the version',
    () async {
      updater.next = update('99.0.0');
      await service.checkForUpdate();
      await updates.settled;
      expect(center.value.single.id, '99.0.0');
      expect(center.value.single.actions.map((action) => action.label), [
        'View',
        'Download',
      ]);
      await center.markRead(center.value);
      final previous = center.activation(center.value.single);
      await service.checkForUpdate();
      await updates.settled;
      expect(center.unreadCount, 0);
      expect(center.isCurrent(previous), isTrue);
      await previous.binding!.onActivate!(previous.notice.actions.last);
      expect(downloads, ['99.0.0']);
    },
  );

  test(
    'startup without a check and network failure retain unconfirmed saved notices',
    () async {
      updater.next = update('99.0.0');
      await service.checkForUpdate();
      await updates.settled;
      await updates.dispose();
      service.dispose();
      center.dispose();
      center = NotificationCenter(preferences: preferences);
      updater = _Updater()..fail = true;
      service = UpdateCheckService(
        settingsService: settings,
        webUIStorage: WebUIStorage(SettingsController(settings)),
        updater: updater,
        platformIsAndroid: true,
        platformIsMacOS: false,
        externallyManaged: false,
      );
      updates = UpdateNotifications(
        center: center,
        service: service,
        onDownload: (_) async {},
      );
      await updates.settled;
      expect(center.value.single.id, '99.0.0');
      expect(center.isConfirmed(center.value.single), isFalse);
      await service.checkForUpdate(quiet: true);
      await updates.settled;
      expect(center.value.single.id, '99.0.0');
      expect(center.isConfirmed(center.value.single), isFalse);
      updater.fail = false;
      await service.checkForUpdate();
      await updates.settled;
      expect(center.value, isEmpty);
    },
  );

  test(
    'a newer version replaces the reserved host entry and becomes unread',
    () async {
      service.debugForceUpdate(version: '99.0.0');
      await updates.settled;
      await center.markRead(center.value);
      service.debugForceUpdate(version: '100.0.0');
      await updates.settled;
      expect(center.value.single.id, '100.0.0');
      expect(center.unreadCount, 1);
    },
  );

  test(
    'dismissing an unconfirmed restored update skips its saved version',
    () async {
      updater.next = update('99.0.0');
      await service.checkForUpdate();
      await updates.settled;
      await restart();
      final notice = center.value.single;
      expect(service.hasCompletedCheck, isFalse);
      expect(center.isConfirmed(notice), isFalse);
      expect(center.isCurrent(center.activation(notice)), isFalse);
      await center.dismissByUser(notice);
      expect(await settings.skippedVersion(), '99.0.0');
      expect(center.value, isEmpty);
      expect(downloads, isEmpty);
      updater.next = update('99.0.0');
      await service.checkForUpdate();
      await updates.settled;
      expect(center.value, isEmpty);
      updater.next = update('100.0.0');
      await service.checkForUpdate();
      await updates.settled;
      expect(center.value.single.id, '100.0.0');
    },
  );

  test(
    'revalidation enables restored actions without resetting read state',
    () async {
      updater.next = update('99.0.0');
      await service.checkForUpdate();
      await updates.settled;
      await center.markRead(center.value);
      await restart();
      final unconfirmed = center.activation(center.value.single);
      expect(center.isCurrent(unconfirmed), isFalse);
      updater.next = update('99.0.0');
      await service.checkForUpdate();
      await updates.settled;
      expect(center.isConfirmed(center.value.single), isTrue);
      expect(center.unreadCount, 0);
      expect(center.isCurrent(unconfirmed), isFalse);
      final confirmed = center.activation(center.value.single);
      await confirmed.binding!.onActivate!(confirmed.notice.actions.last);
      expect(downloads, ['99.0.0']);
      await service.checkForUpdate();
      await updates.settled;
      expect(center.isCurrent(confirmed), isTrue);
    },
  );

  test('failed restored-notice removal does not skip the update', () async {
    updater.next = update('99.0.0');
    await service.checkForUpdate();
    await updates.settled;
    await restart(failSave: true);
    final notice = center.value.single;
    await expectLater(
      center.dismissByUser(notice),
      throwsA(isA<NotificationStorageException>()),
    );
    expect(center.value.single, same(notice));
    expect(center.isConfirmed(notice), isFalse);
    expect(await settings.skippedVersion(), isNull);
  });

  test(
    'dismissal skips the displayed version rather than a newer asynchronous result',
    () async {
      service.debugForceUpdate(version: '99.0.0');
      await updates.settled;
      final old = center.value.single;
      service.debugForceUpdate(version: '100.0.0');
      await center.dismissByUser(old);
      await updates.settled;
      expect(await settings.skippedVersion(), '99.0.0');
      expect(service.availableUpdate!.version, '100.0.0');
      expect(center.value.single.id, '100.0.0');
    },
  );

  test(
    'confirmed no update removes the saved notice without skipping it',
    () async {
      service.debugForceUpdate(version: '99.0.0');
      await updates.settled;
      await service.checkForUpdate();
      await updates.settled;
      expect(center.value, isEmpty);
      expect(await settings.skippedVersion(), isNull);
    },
  );

  for (final reason in ['installed', 'skipped']) {
    test(
      '$reason versions are removed from saved notices before checking the network',
      () async {
        await updates.dispose();
        final version = reason == 'installed' ? BuildInfo.version : '99.0.0';
        await center.publish(
          NativeNotification(
            namespace: NotificationNamespace.host,
            sourceId: UpdateNotifications.sourceId,
            sourceName: 'Decaid',
            id: version,
            message: 'Update available: $version',
          ),
        );
        if (reason == 'skipped') await settings.setSkippedVersion(version);
        center.dispose();
        center = NotificationCenter(preferences: preferences);
        updates = UpdateNotifications(
          center: center,
          service: service,
          onDownload: (_) async {},
        );
        await updates.settled;
        expect(center.value, isEmpty);
        expect(service.hasCompletedCheck, isFalse);
      },
    );
  }
}
