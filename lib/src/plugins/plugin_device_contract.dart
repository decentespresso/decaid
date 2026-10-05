import 'package:reaprime/src/models/device/device.dart';

import 'plugin_device_surface_authority.dart';

enum PluginDeviceOperation {
  connect,
  disconnect,
  execute,
  create,
  bleEvent,
  tare,
  startTimer,
  stopTimer,
  resetTimer,
  sleepDisplay,
  wakeDisplay,
  start,
  stop,
  setGrindSetting,
  setRpm,
}

typedef PluginDeviceInvoker =
    Future<Map<String, dynamic>> Function(
      PluginDeviceOperation operation,
      Map<String, dynamic> payload,
    );

class PluginDeviceException implements Exception {
  final String message;
  final String code;
  const PluginDeviceException(
    this.message, {
    this.code = 'plugin_device_error',
  });
  @override
  String toString() => message;
}

abstract class PluginDeviceAdapter implements Device {
  PluginDeviceSurfaceAuthority? get surfaceAuthority;
  void publishInfo(Map<String, dynamic> info, {String? session});
  void publish(Map<String, dynamic> snapshot, {String? session});
  void reportDisconnected({String? session});
  Future<void> dispose();
}
