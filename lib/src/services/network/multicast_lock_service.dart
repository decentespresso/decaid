import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

class MulticastLockService {
  static const MethodChannel _channel = MethodChannel('com.reaprime/network');
  final Logger _log = Logger('MulticastLockService');

  Future<bool> acquire() async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? held = await _channel.invokeMethod('acquireMulticastLock');
      _log.info('MulticastLock acquire -> held=$held');
      return held ?? false;
    } on PlatformException catch (e, st) {
      _log.warning('Failed to acquire MulticastLock: ${e.message}', e, st);
      return false;
    }
  }

  Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('releaseMulticastLock');
      _log.info('MulticastLock released');
    } on PlatformException catch (e) {
      _log.warning('Failed to release MulticastLock: ${e.message}');
    }
  }

  Future<bool> isHeld() async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? held = await _channel.invokeMethod('isMulticastLockHeld');
      return held ?? false;
    } on PlatformException catch (e) {
      _log.warning('Failed to query MulticastLock state: ${e.message}');
      return false;
    }
  }
}
