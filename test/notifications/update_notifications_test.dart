import 'dart:async';
import 'dart:io';

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
  final download = Completer<String>();
  final installation = Completer<ApkInstallOutcome>();
  void Function(double)? progress;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    if (fail) throw StateError('Offline');
    return next;
  }

  @override
  Future<String> downloadUpdate(
    UpdateInfo update, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) {
    progress = onProgress;
    return download.future;
  }

  @override
  Future<ApkInstallOutcome> installUpdate(
    String path, {
    bool requestPermission = true,
  }) => installation.future;
}

void main() {
  late Directory directory;
  late String downloadPath;
  late SharedPreferences preferences;
  late NotificationCenter center;
  late UpdateCheckService service;
  late UpdateNotifications updates;
  late MockSettingsService settings;
  late _Updater updater;
  final views = <String>[];

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
      onView: (info) async => views.add(info.version),
    );
    await updates.settled;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('update-notices-');
    downloadPath = '${directory.path}/update.apk';
    await File(downloadPath).writeAsBytes([1, 2, 3]);
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
    views.clear();
    updates = UpdateNotifications(
      center: center,
      service: service,
      onView: (info) async => views.add(info.version),
    );
    await updates.settled;
  });

  tearDown(() async {
    await updates.dispose();
    service.dispose();
    center.dispose();
    await directory.delete(recursive: true);
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
      ]);
      expect(
        center.value.single.actions.single.type,
        NotificationActionType.viewUpdate,
      );
      await center.markRead(center.value);
      final previous = center.activation(center.value.single);
      await service.checkForUpdate();
      await updates.settled;
      expect(center.unreadCount, 0);
      expect(center.isCurrent(previous), isTrue);
      await previous.binding!.onActivate!(previous.notice.actions.first);
      expect(views, ['99.0.0']);
    },
  );

  test(
    'unchanged confirmed notices retain activation without persistence writes',
    () async {
      await updates.dispose();
      center.dispose();
      var saves = 0;
      center = NotificationCenter(
        save: (_) async {
          saves++;
          return true;
        },
      );
      updates = UpdateNotifications(
        center: center,
        service: service,
        onView: (info) async => views.add(info.version),
      );
      await updates.settled;
      updater.next = update('99.0.0');
      await service.checkForUpdate();
      await updates.settled;
      await center.markRead(center.value);
      final notice = center.value.single;
      final activation = center.activation(notice);
      final saved = saves;
      var changes = 0;
      center.addListener(() => changes++);

      await service.checkForUpdate();
      await updates.settled;

      expect(saves, saved);
      expect(changes, 0);
      expect(center.value.single, same(notice));
      expect(center.unreadCount, 0);
      expect(center.isCurrent(activation), isTrue);
      await activation.binding!.onActivate!(notice.actions.single);
      expect(views, ['99.0.0']);

      await center.removeSource(
        NotificationNamespace.host,
        UpdateNotifications.sourceId,
      );
      await service.checkForUpdate();
      await updates.settled;

      expect(center.value.single.id, '99.0.0');
      expect(center.isConfirmed(center.value.single), isTrue);
      expect(center.isCurrent(activation), isFalse);
    },
  );

  test(
    'revalidating legacy actions preserves a read restored notice',
    () async {
      await center.publish(
        NativeNotification(
          namespace: NotificationNamespace.host,
          sourceId: UpdateNotifications.sourceId,
          sourceName: 'Decaid',
          id: '99.0.0',
          message: 'Update available: 99.0.0',
          actions: const [
            NotificationAction(
              id: 'download',
              label: 'Download',
              type: NotificationActionType.downloadUpdate,
            ),
          ],
        ),
      );
      await center.markRead(center.value);
      await restart();
      final restored = center.activation(center.value.single);
      expect(center.isCurrent(restored), isFalse);

      updater.next = update('99.0.0');
      await service.checkForUpdate();
      await updates.settled;

      expect(center.unreadCount, 0);
      expect(
        center.value.single.actions.single.type,
        NotificationActionType.viewUpdate,
      );
      expect(center.isCurrent(restored), isFalse);
      final confirmed = center.activation(center.value.single);
      await confirmed.binding!.onActivate!(confirmed.notice.actions.single);
      expect(views, ['99.0.0']);
    },
  );

  test(
    'download and installation progress do not rewrite saved notices',
    () async {
      await updates.dispose();
      center.dispose();
      var saves = 0;
      center = NotificationCenter(
        save: (_) async {
          saves++;
          return true;
        },
      );
      updates = UpdateNotifications(
        center: center,
        service: service,
        onView: (_) async {},
      );
      service.debugForceUpdate(version: '99.0.0');
      await updates.settled;
      final notice = center.value.single;
      final activation = center.activation(notice);
      final beforeDownload = saves;
      final downloading = service.downloadUpdate(
        service.availableUpdate!,
        (_) {},
      );
      updater.progress!(0.25);
      updater.progress!(0.5);
      await updates.settled;
      expect(saves, beforeDownload);
      expect(center.value.single, same(notice));
      expect(center.isCurrent(activation), isTrue);
      updater.download.complete(downloadPath);
      await downloading;
      await updates.settled;
      final beforeInstall = saves;
      final installing = service.installUpdate(service.downloadedPath!);
      await updates.settled;
      updater.installation.complete(ApkInstallOutcome.installerLaunched);
      await installing;
      await updates.settled;
      expect(saves, beforeInstall);
      expect(center.isCurrent(activation), isTrue);
    },
  );

  test(
    'an active download can publish and revalidate its update notice',
    () async {
      service.debugForceUpdate(version: '99.0.0');
      await updates.settled;
      final downloading = service.downloadUpdate(
        service.availableUpdate!,
        (_) {},
      );
      await updates.dispose();
      await center.removeSource(
        NotificationNamespace.host,
        UpdateNotifications.sourceId,
      );
      for (var attachment = 0; attachment < 2; attachment++) {
        updates = UpdateNotifications(
          center: center,
          service: service,
          onView: (_) async {},
        );
        await updates.settled;
        expect(center.value.single.id, '99.0.0');
        expect(center.isConfirmed(center.value.single), isTrue);
        if (attachment == 0) await updates.dispose();
      }
      updater.download.complete(downloadPath);
      await downloading;
      await updates.settled;
    },
  );

  test('startup without a check and network failure retain unconfirmed saved notices', () async {
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
      onView: (_) async {},
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
  });

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

  test('restored update cannot be viewed before source revalidation', () async {
    updater.next = update('99.0.0');
    await service.checkForUpdate();
    await updates.settled;
    await restart();
    final notice = center.value.single;
    expect(service.hasCompletedCheck, isFalse);
    expect(center.isConfirmed(notice), isFalse);
    expect(center.isCurrent(center.activation(notice)), isFalse);
    expect(center.activation(notice).binding?.onActivate, isNull);
    expect(await settings.skippedVersion(), isNull);
    expect(center.value, hasLength(1));
    expect(views, isEmpty);
    updater.next = update('99.0.0');
    await service.checkForUpdate();
    await updates.settled;
    final current = center.activation(center.value.single);
    await current.binding!.onActivate!(current.notice.actions.single);
    await updates.settled;
    expect(await settings.skippedVersion(), isNull);
    expect(views, ['99.0.0']);
    expect(center.value.single.id, '99.0.0');
    updater.next = update('100.0.0');
    await service.checkForUpdate();
    await updates.settled;
    expect(center.value.single.id, '100.0.0');
  });

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
      await confirmed.binding!.onActivate!(confirmed.notice.actions.single);
      expect(views, ['99.0.0']);
      await service.checkForUpdate();
      await updates.settled;
      expect(center.isCurrent(confirmed), isTrue);
    },
  );

  test(
    'failed source resolution preserves the notice and does not skip',
    () async {
      updater.next = update('99.0.0');
      await service.checkForUpdate();
      await updates.settled;
      await restart(failSave: true);
      final notice = center.value.single;
      await expectLater(
        center.removeSource(
          NotificationNamespace.host,
          UpdateNotifications.sourceId,
          notice.id,
        ),
        throwsA(isA<NotificationStorageException>()),
      );
      expect(center.value.single, same(notice));
      expect(center.isConfirmed(notice), isFalse);
      expect(await settings.skippedVersion(), isNull);
    },
  );

  test(
    'a replaced update cannot open its stale version before synchronization',
    () async {
      service.debugForceUpdate(version: '99.0.0');
      await updates.settled;
      final old = center.activation(center.value.single);
      service.debugForceUpdate(version: '100.0.0');
      await old.binding!.onActivate!(old.notice.actions.first);
      await updates.settled;
      expect(await settings.skippedVersion(), isNull);
      expect(views, isEmpty);
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
          onView: (_) async {},
        );
        await updates.settled;
        expect(center.value, isEmpty);
        expect(service.hasCompletedCheck, isFalse);
      },
    );
  }
}
