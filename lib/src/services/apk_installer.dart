import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

class InvalidApkException implements Exception {
  const InvalidApkException();
}

class ApkInstaller {
  ApkInstaller({bool? platformIsAndroid})
    : _isAndroid = platformIsAndroid ?? Platform.isAndroid;

  final bool _isAndroid;
  static const MethodChannel _channel = MethodChannel(
    'com.reaprime.updater/apk_installer',
  );
  final Logger _log = Logger('ApkInstaller');

  Future<bool> isValidApk(String path) async {
    try {
      final file = await File(path).stat();
      if (file.type != FileSystemEntityType.file || file.size == 0) {
        return false;
      }
      if (!_isAndroid) return false;
      return await _channel.invokeMethod<bool>('isValidApk', {
            'apkPath': path,
          }) ??
          false;
    } on FileSystemException {
      return false;
    }
  }

  Future<bool> installApk(String apkPath) async {
    if (!_isAndroid) {
      throw UnsupportedError('APK installation is only supported on Android');
    }

    try {
      _log.info('Installing APK from $apkPath');

      final bool? result = await _channel.invokeMethod('installApk', {
        'apkPath': apkPath,
      });

      return result ?? false;
    } on PlatformException catch (e, stackTrace) {
      if (e.code == 'INVALID_APK') throw const InvalidApkException();
      _log.severe('Failed to install APK: ${e.message}', e, stackTrace);
      rethrow;
    }
  }

  Future<bool> canInstallPackages() async {
    if (!_isAndroid) {
      return false;
    }

    try {
      final bool? result = await _channel.invokeMethod('canInstallPackages');
      return result ?? false;
    } on PlatformException catch (e) {
      _log.warning('Failed to check install permission: ${e.message}');
      return false;
    }
  }

  Future<void> requestInstallPermission() async {
    if (!_isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod('requestInstallPermission');
    } on PlatformException catch (e) {
      _log.warning('Failed to request install permission: ${e.message}');
      rethrow;
    }
  }
}
