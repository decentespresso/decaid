import 'dart:io';

import 'package:flutter/services.dart';

/// Grants temporary read access to directories picked through the iOS
/// document picker. file_picker's getDirectoryPath uses
/// UIDocumentPickerModeOpen, which returns security-scoped URLs that fail
/// with EPERM unless the app starts accessing them.
class SecurityScopedFileService {
  SecurityScopedFileService._();

  static const MethodChannel _channel = MethodChannel(
    'com.reaprime/security_scoped',
  );

  static Future<bool> startAccessing(String path) async {
    if (!Platform.isIOS) return true;
    final bool? ok = await _channel.invokeMethod('startAccessing', path);
    return ok ?? false;
  }

  static Future<void> stopAccessing(String path) async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod('stopAccessing', path);
  }
}
