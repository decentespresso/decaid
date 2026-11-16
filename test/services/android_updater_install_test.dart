import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/apk_installer.dart';

class _Installer extends ApkInstaller {
  bool valid = false;
  List<String> calls = const [];

  @override
  Future<bool> isValidApk(String path) async {
    calls = [...calls, 'validate:$path'];
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
}
