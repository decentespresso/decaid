import 'dart:io';

import 'package:flutter/services.dart';

class SecurityScopedFileService {
  SecurityScopedFileService._();

  static const MethodChannel _channel = MethodChannel(
    'com.reaprime/security_scoped',
  );
  static String? _activePath;

  static Future<bool> startAccessing(String path) async {
    if (!Platform.isIOS) return true;
    final previous = _activePath;
    _activePath = path;
    if (previous != null && previous != path) {
      await _channel.invokeMethod('stopAccessing', previous);
    }
    final bool? ok = await _channel.invokeMethod('startAccessing', path);
    return ok ?? false;
  }

  static Future<void> stopAccessing(String path) async {
    if (!Platform.isIOS) return;
    if (_activePath == path) {
      _activePath = null;
    }
    await _channel.invokeMethod('stopAccessing', path);
  }
}
