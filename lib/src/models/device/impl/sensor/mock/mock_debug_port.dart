import 'dart:async';

import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';

class MockDebugPort implements Sensor, SimulatedDevice {
  @override
  Stream<ConnectionState> get connectionState =>
      BehaviorSubject.seeded(ConnectionState.connected);

  final BehaviorSubject<Map<String, dynamic>> _streamSubject =
      BehaviorSubject();
  @override
  Stream<Map<String, dynamic>> get data => _streamSubject.stream;

  @override
  String get deviceId => "mockDebugPort";

  @override
  DeviceImplementation get implementation => DeviceImplementation.debugPort;

  @override
  TransportType get transportType => TransportType.unknown;

  bool _ignoreTimer = false;

  @override
  disconnect() async {
    _timer.cancel();
  }

  @override
  Future<Map<String, dynamic>> execute(
    String commandId,
    Map<String, dynamic>? parameters,
  ) async {
    if (commandId != "input") {
      throw "Invalid command";
    }
    if (parameters == null) {
      throw 'Parameter "command" required';
    }

    final command = parameters["command"];

    if (command == null || command.runtimeType != String) {
      throw 'Invalid "command" type: ${command.runtimeType}';
    }

    if ((command as String).contains("!")) {
      _ignoreTimer = true;
    }
    final response = {
      "timestamp": "${DateTime.timestamp()}",
      "output": "[DEBUG] execute: $command",
    };

    _streamSubject.add(response);
    if (command == "q") {
      _ignoreTimer = false;
    }
    return response;
  }

  @override
  SensorInfo get info => SensorInfo(
    name: "DebugPort",
    vendor: "DecentEspresso",
    dataChannels: [DataChannel(key: "output", type: "string")],
    commands: [
      CommandDescriptor(
        id: "input",
        name: "input",
        description: "Send line to debug port",
        paramsSchema: {"command": "string"},
        resultsSchema: null,
      ),
    ],
  );

  @override
  String get name => "DebugPort";

  late Timer _timer;

  @override
  Future<void> onConnect() async {
    _timer = Timer.periodic(Duration(milliseconds: 500), (t) {
      if (_ignoreTimer) {
        return;
      }
      _streamSubject.add({
        "timestamp": "${DateTime.timestamp()}",
        "output": "R 1234567",
      });
    });
  }

  @override
  DeviceType get type => DeviceType.sensor;
}
