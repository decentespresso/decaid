import 'dart:async';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';

import 'plugin_device_service.dart';
import 'plugin_protocol_device.dart';

class PluginBoundSensor extends PluginProtocolDevice implements Sensor {
  PluginBoundSensor({
    required super.deviceId,
    required super.name,
    required super.invoke,
    required super.transportType,
    super.prepareConnection,
    required super.onReady,
    required super.invocationTimeout,
    required Map<String, dynamic> definition,
  }) : info = SensorInfo(
         name: name,
         vendor: definition['vendor'] is String
             ? definition['vendor'] as String
             : '',
         dataChannels: parsePluginDataChannels(definition['dataChannels']),
         commands: parsePluginCommands(definition['commands']),
       );

  final StreamController<Map<String, dynamic>> _data =
      StreamController.broadcast();

  @override
  final SensorInfo info;
  @override
  DeviceType get type => DeviceType.sensor;
  @override
  Stream<Map<String, dynamic>> get data => _data.stream;

  @override
  void publish(Map<String, dynamic> snapshot, {String? session}) {
    checkSession(session);
    validatePluginSensorSnapshot(snapshot, {
      for (final channel in info.dataChannels) channel.key: channel,
    });
    _data.add(Map.unmodifiable(snapshot));
  }

  @override
  Future<Map<String, dynamic>> execute(
    String commandId,
    Map<String, dynamic>? parameters,
  ) async {
    if (info.commands?.any((command) => command.id == commandId) != true) {
      throw PluginDeviceException('Unknown sensor command: $commandId');
    }
    validatePluginDevicePayload(parameters ?? const {}, 'Sensor command');
    final result = await invoke(PluginDeviceOperation.execute, {
      'commandId': commandId,
      'params': parameters,
    });
    validatePluginDevicePayload(result, 'Sensor command result');
    return result;
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    if (!_data.isClosed) await _data.close();
  }
}
