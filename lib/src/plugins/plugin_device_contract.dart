import 'package:reaprime/src/models/device/device.dart';

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

class PluginDeviceSettings {
  final String pluginId;
  final String endpointId;

  const PluginDeviceSettings({
    required this.pluginId,
    required this.endpointId,
  });
}

abstract interface class DeviceSettingsCapable implements Device {
  PluginDeviceSettings? get deviceSettings;
}

abstract class PluginDeviceAdapter implements Device {
  void publish(Map<String, dynamic> snapshot, {String? session});
  void reportDisconnected({String? session});
  Future<void> dispose();
}
