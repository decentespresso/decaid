import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/apk_install_coordinator.dart';
import 'package:reaprime/src/services/apk_installer.dart';

class _Installer extends ApkInstaller {
  bool allowed = false;
  int requests = 0;
  int installs = 0;
  bool launchResult = true;
  Object? requestError;

  @override
  Future<bool> canInstallPackages() async => allowed;

  @override
  Future<void> requestInstallPermission() async {
    requests++;
    if (requestError case final error?) throw error;
  }

  @override
  Future<bool> installApk(String apkPath) async {
    installs++;
    return launchResult;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Installer installer;
  late ApkInstallCoordinator coordinator;

  setUp(() {
    installer = _Installer();
    coordinator = ApkInstallCoordinator(installer);
  });

  tearDown(() => coordinator.dispose());

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  void leaveAndReturn() {
    coordinator.didChangeAppLifecycleState(AppLifecycleState.inactive);
    coordinator.didChangeAppLifecycleState(AppLifecycleState.paused);
    coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
  }

  test('authorized installation launches immediately', () async {
    installer.allowed = true;
    expect(
      await coordinator.install('/update.apk'),
      ApkInstallOutcome.installerLaunched,
    );
    expect(installer.requests, 0);
    expect(installer.installs, 1);
  });

  test(
    'grant on return automatically installs once and coalesces taps',
    () async {
      final first = coordinator.install('/update.apk');
      final second = coordinator.install('/update.apk');
      await flush();
      expect(installer.requests, 1);
      expect(installer.installs, 0);
      installer.allowed = true;
      leaveAndReturn();
      leaveAndReturn();
      expect(await first, ApkInstallOutcome.installerLaunched);
      expect(await second, ApkInstallOutcome.installerLaunched);
      expect(installer.installs, 1);
    },
  );

  test('denial is neutral and retry reuses the supplied path', () async {
    final first = coordinator.install('/update.apk');
    await flush();
    leaveAndReturn();
    expect(await first, ApkInstallOutcome.permissionRequired);
    expect(installer.installs, 0);
    installer.allowed = true;
    expect(
      await coordinator.install('/update.apk'),
      ApkInstallOutcome.installerLaunched,
    );
    expect(installer.requests, 1);
    expect(installer.installs, 1);
  });

  test('remote preflight never requests local permission', () async {
    expect(
      await coordinator.install('/update.apk', requestPermission: false),
      ApkInstallOutcome.permissionRequired,
    );
    expect(installer.requests, 0);
    expect(installer.installs, 0);
  });

  test('unrelated resumes do not finish a permission attempt', () async {
    var completed = false;
    final pending = coordinator.install('/update.apk').then((value) {
      completed = true;
      return value;
    });
    await flush();
    coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await flush();
    expect(completed, isFalse);
    expect(installer.installs, 0);
    leaveAndReturn();
    expect(await pending, ApkInstallOutcome.permissionRequired);
  });

  test(
    'dispose cancels the pending attempt and prevents a later install',
    () async {
      final pending = coordinator.install('/update.apk');
      await flush();
      coordinator.dispose();
      installer.allowed = true;
      leaveAndReturn();
      expect(await pending, ApkInstallOutcome.cancelled);
      expect(installer.installs, 0);
      final replacement = ApkInstallCoordinator(installer);
      replacement.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await flush();
      expect(installer.installs, 0);
      replacement.dispose();
    },
  );

  test(
    'permission screen and installer failures remain genuine failures',
    () async {
      installer.requestError = StateError('permission screen unavailable');
      await expectLater(coordinator.install('/update.apk'), throwsStateError);
      installer.requestError = null;
      installer.allowed = true;
      installer.launchResult = false;
      await expectLater(coordinator.install('/update.apk'), throwsStateError);
    },
  );
}
