import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/apk_installer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.reaprime.updater/apk_installer');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ApkInstaller installer;

  setUp(() => installer = ApkInstaller(platformIsAndroid: true));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('permission request waits for the native activity result', () async {
    final returned = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (_) => returned.future);
    var completed = false;
    final pending = installer.requestInstallPermission().then((_) {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    returned.complete();
    await pending;
    expect(completed, isTrue);
  });

  test(
    'missing, empty and non-file APK paths never reach the native bridge',
    () async {
      final directory = await Directory.systemTemp.createTemp('apk-preflight-');
      addTearDown(() => directory.delete(recursive: true));
      final empty = File('${directory.path}/empty.apk');
      await empty.writeAsBytes([]);
      var nativeCalls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        nativeCalls++;
        return true;
      });

      for (final path in [
        directory.path,
        empty.path,
        '${directory.path}/missing.apk',
      ]) {
        expect(await installer.isValidApk(path), isFalse);
      }
      expect(nativeCalls, 0);
    },
  );

  test(
    'native invalid APK failures use the shared validation exception',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'INVALID_APK', message: 'APK is invalid');
      });

      await expectLater(
        installer.installApk('/cached.apk'),
        throwsA(isA<InvalidApkException>()),
      );
    },
  );

  test('other native installation failures remain genuine errors', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'INSTALL_FAILED');
    });

    await expectLater(
      installer.installApk('/cached.apk'),
      throwsA(isA<PlatformException>()),
    );
  });
}
