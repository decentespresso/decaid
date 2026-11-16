import 'dart:async';

import 'package:flutter/services.dart';

import 'apk_installer.dart';

export 'apk_installer.dart' show InvalidApkException;

enum ApkInstallOutcome { installerLaunched, permissionRequired, cancelled }

class ApkInstallCoordinator {
  ApkInstallCoordinator(this._installer);

  final ApkInstaller _installer;
  Future<ApkInstallOutcome>? _operation;
  Completer<void>? _permissionReturn;
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
      final cancelled = Completer<void>();
      _permissionReturn = cancelled;
      try {
        await Future.any([
          _installer.requestInstallPermission(),
          cancelled.future,
        ]);
      } on PlatformException catch (error) {
        if (error.code == 'PERMISSION_CANCELLED') {
          return ApkInstallOutcome.cancelled;
        }
        rethrow;
      } finally {
        _permissionReturn = null;
      }
      if (_disposed) return ApkInstallOutcome.cancelled;
      if (!await _installer.canInstallPackages()) {
        return ApkInstallOutcome.permissionRequired;
      }
      if (_disposed) return ApkInstallOutcome.cancelled;
      final valid = await _installer.isValidApk(path);
      if (_disposed) return ApkInstallOutcome.cancelled;
      if (!valid) throw const InvalidApkException();
    }
    if (_disposed) return ApkInstallOutcome.cancelled;
    if (!await _installer.installApk(path)) {
      throw StateError('Android installer could not be opened');
    }
    return ApkInstallOutcome.installerLaunched;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final returned = _permissionReturn;
    if (returned != null && !returned.isCompleted) returned.complete();
  }
}
