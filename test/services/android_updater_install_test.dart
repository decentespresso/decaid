import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/apk_installer.dart';

class _Installer extends ApkInstaller {
  bool valid = false;
  Completer<bool>? validation;
  List<String> calls = const [];

  @override
  Future<bool> isValidApk(String path) async {
    calls = [...calls, 'validate:$path'];
    if (validation case final pending?) return pending.future;
    return valid;
  }

  @override
  Future<bool> canInstallPackages() async {
    calls = [...calls, 'permission'];
    return true;
  }

  @override
  Future<void> requestInstallPermission() async {
    calls = [...calls, 'request'];
  }

  @override
  Future<bool> installApk(String path) async {
    calls = [...calls, 'install:$path'];
    return true;
  }
}

class _PendingInstaller extends ApkInstaller {
  _PendingInstaller() : super(platformIsAndroid: true);

  bool allowed = false;
  int requests = 0;
  int installs = 0;
  final returned = Completer<void>();

  @override
  Future<bool> isValidApk(String path) async => true;

  @override
  Future<bool> canInstallPackages() async => allowed;

  @override
  Future<void> requestInstallPermission() async {
    requests++;
    await returned.future;
  }

  @override
  Future<bool> installApk(String apkPath) async {
    installs++;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Installer installer;
  late AndroidUpdater updater;
  setUp(() {
    installer = _Installer();
    updater = AndroidUpdater(
      owner: 'decentespresso',
      repo: 'decaid',
      apkInstaller: installer,
      platformIsAndroid: true,
    );
  });

  tearDown(() => updater.dispose());

  for (final requestPermission in [true, false]) {
    test(
      'invalid APK has no install side effects ($requestPermission)',
      () async {
        await expectLater(
          updater.installUpdate(
            '/update.apk',
            requestPermission: requestPermission,
          ),
          throwsA(isA<InvalidApkException>()),
        );
        expect(installer.calls, ['validate:/update.apk']);
      },
    );
  }

  test('valid APK is checked before authorized installer launch', () async {
    installer.valid = true;
    expect(
      await updater.installUpdate('/update.apk'),
      ApkInstallOutcome.installerLaunched,
    );
    expect(installer.calls, [
      'validate:/update.apk',
      'permission',
      'install:/update.apk',
    ]);
  });

  test(
    'disposal during validation prevents later permission or install work',
    () async {
      installer.validation = Completer<bool>();
      final pending = updater.installUpdate('/update.apk');
      await Future<void>.delayed(Duration.zero);
      updater.dispose();
      installer.validation!.complete(true);

      expect(await pending, ApkInstallOutcome.cancelled);
      expect(installer.calls, ['validate:/update.apk']);
    },
  );

  test('cancelling during native validation prevents a late launch', () async {
    installer.valid = true;
    installer.validation = Completer<bool>();
    final pending = updater.installUpdate('/update.apk');
    await Future<void>.delayed(Duration.zero);
    expect(installer.calls, ['validate:/update.apk']);

    updater.cancelInstall();
    installer.validation!.complete(true);

    expect(await pending, ApkInstallOutcome.cancelled);
    expect(installer.calls, ['validate:/update.apk']);

    installer.validation = null;
    expect(
      await updater.installUpdate('/update.apk'),
      ApkInstallOutcome.installerLaunched,
    );
    expect(installer.calls, [
      'validate:/update.apk',
      'validate:/update.apk',
      'permission',
      'install:/update.apk',
    ]);
  });

  for (final invalidation in ['removed', 'empty']) {
    test('APK $invalidation during permission settings is discarded', () async {
      const channel = MethodChannel('com.reaprime.updater/apk_installer');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final directory = await Directory.systemTemp.createTemp('update-return-');
      addTearDown(() => directory.delete(recursive: true));
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final file = File('${directory.path}/update.apk');
      await file.writeAsBytes([1, 2, 3]);
      final requested = Completer<void>();
      final returned = Completer<void>();
      var allowed = false;
      var installs = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'isValidApk':
            return true;
          case 'canInstallPackages':
            return allowed;
          case 'requestInstallPermission':
            requested.complete();
            await returned.future;
            return null;
          case 'installApk':
            installs++;
            return true;
          default:
            throw StateError('Unexpected method: ${call.method}');
        }
      });
      final candidate = AndroidUpdater(
        owner: 'test',
        repo: 'test',
        apkInstaller: ApkInstaller(platformIsAndroid: true),
        platformIsAndroid: true,
      );
      addTearDown(candidate.dispose);
      final pending = candidate.installUpdate(file.path);
      await requested.future;

      if (invalidation == 'removed') {
        await file.delete();
      } else {
        await file.writeAsBytes([]);
      }
      allowed = true;
      returned.complete();

      await expectLater(pending, throwsA(isA<InvalidApkException>()));
      expect(installs, 0);
    });
  }

  test(
    'cancelling a pending permission attempt prevents a late launch',
    () async {
      final installer = _PendingInstaller();
      final candidate = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        apkInstaller: installer,
        platformIsAndroid: true,
      );
      addTearDown(candidate.dispose);

      final pending = candidate.installUpdate('/update.apk');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(installer.requests, 1);

      candidate.cancelInstall();
      installer.allowed = true;
      installer.returned.complete();

      expect(await pending, ApkInstallOutcome.cancelled);
      expect(installer.installs, 0);
      expect(
        await candidate.installUpdate('/update.apk'),
        ApkInstallOutcome.installerLaunched,
      );
      expect(installer.installs, 1);
    },
  );
}
