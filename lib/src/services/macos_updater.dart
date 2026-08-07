import 'dart:io';

import 'package:flutter/services.dart';
import 'package:reaprime/src/services/android_updater.dart' show UpdateChannel;

class MacOSUpdater {
  static const MethodChannel _channel = MethodChannel(
    'net.tadel.reaprime/macos_updater',
  );

  final bool _supported;
  bool _available = false;

  MacOSUpdater({bool? supported}) : _supported = supported ?? Platform.isMacOS;

  bool get isSupported => _supported;

  bool get isAvailable => _supported && _available;

  Future<void> configure({
    required bool automaticChecks,
    required UpdateChannel channel,
  }) async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('configure', {
      'automaticChecks': automaticChecks,
      'channel': channel.name,
    });
    _available = true;
  }

  Future<void> setAutomaticChecks(bool enabled) async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>('setAutomaticChecks', {
      'enabled': enabled,
    });
  }

  Future<void> setChannel(UpdateChannel channel) async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>('setChannel', {'channel': channel.name});
  }

  Future<void> checkForUpdates() async {
    if (!isAvailable) return;
    await _channel.invokeMethod<void>('checkForUpdates');
  }
}
