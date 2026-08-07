import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

class ApkInstaller {
  static const MethodChannel _channel = MethodChannel(
    'com.reaprime.updater/apk_installer',
  );
  final Logger _log = Logger('ApkInstaller');

  Future<bool> installApk(String apkPath) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('APK installation is only supported on Android');
    }

    try {
      _log.info('Installing APK from $apkPath');

      final bool? result = await _channel.invokeMethod('installApk', {
        'apkPath': apkPath,
      });

      return result ?? false;
    } on PlatformException catch (e, stackTrace) {
      _log.severe('Failed to install APK: ${e.message}', e, stackTrace);
      rethrow;
    }
  }

  Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) {
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
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await _channel.invokeMethod('requestInstallPermission');
    } on PlatformException catch (e) {
      _log.warning('Failed to request install permission: ${e.message}');
    }
  }
}
