import 'dart:async';

import 'package:flutter/widgets.dart';

import 'apk_installer.dart';

enum ApkInstallOutcome { installerLaunched, permissionRequired, cancelled }

class InvalidApkException implements Exception {
  const InvalidApkException();
}

class ApkInstallCoordinator with WidgetsBindingObserver {
  ApkInstallCoordinator(this._installer);

  final ApkInstaller _installer;
  Future<ApkInstallOutcome>? _operation;
  Completer<void>? _permissionReturn;
  bool _leftApplication = false;
  bool _disposed = false;

  Future<ApkInstallOutcome> install(
    String apkPath, {
    bool requestPermission = true,
  }) {
    if (_disposed) return Future.value(ApkInstallOutcome.cancelled);
    return _operation ??= _install(apkPath, requestPermission).whenComplete(() {
      _operation = null;
    });
  }

  Future<ApkInstallOutcome> _install(
    String path,
    bool requestPermission,
  ) async {
    if (!await _installer.canInstallPackages()) {
      if (_disposed) return ApkInstallOutcome.cancelled;
      if (!requestPermission) return ApkInstallOutcome.permissionRequired;
      final returned = Completer<void>();
      _permissionReturn = returned;
      _leftApplication = false;
      WidgetsBinding.instance.addObserver(this);
      try {
        await _installer.requestInstallPermission();
        await returned.future;
      } finally {
        WidgetsBinding.instance.removeObserver(this);
        _permissionReturn = null;
      }
      if (_disposed) return ApkInstallOutcome.cancelled;
      if (!await _installer.canInstallPackages()) {
        return ApkInstallOutcome.permissionRequired;
      }
    }
    if (_disposed) return ApkInstallOutcome.cancelled;
    if (!await _installer.installApk(path)) {
      throw StateError('Android installer could not be opened');
    }
    return ApkInstallOutcome.installerLaunched;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final returned = _permissionReturn;
    if (_disposed || returned == null || returned.isCompleted) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _leftApplication = true;
    } else if (state == AppLifecycleState.resumed && _leftApplication) {
      returned.complete();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    final returned = _permissionReturn;
    if (returned != null && !returned.isCompleted) returned.complete();
  }
}
