import 'dart:async';

import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

class SensorBasket implements Sensor {
  late Logger _log;
  final SerialTransport _transport;

  SensorBasket({required this._transport}) {
    _log = Logger("SensorBasket");
  }

  final BehaviorSubject<ConnectionState> _connectionSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);
  @override
  Stream<ConnectionState> get connectionState =>
      _connectionSubject.asBroadcastStream();

  @override
  Stream<Map<String, dynamic>> get data => _streamSubject.asBroadcastStream();

  @override
  String get deviceId => _transport.id;

  @override
  DeviceImplementation get implementation => DeviceImplementation.sensorBasket;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  disconnect() async {
    _connectionSubject.add(ConnectionState.disconnected);
    _transportSubscription.cancel();
    await _transport.disconnect();
  }

  @override
  String get name => "SensorBasket";

  late StreamSubscription<String> _transportSubscription;
  final BehaviorSubject<Map<String, dynamic>> _streamSubject =
      BehaviorSubject();

  @override
  Future<void> onConnect() async {
    if (await _connectionSubject.first == ConnectionState.connected) {
      return;
    }
    _log.info("on connect");
    await _transport.connect();
    _transportSubscription = _transport.readStream.listen(
      onData,
      onError: (error) {
        _log.warning("transport error", error);
        disconnect();
      },
      onDone: () {
        disconnect();
      },
    );
    _connectionSubject.add(ConnectionState.connected);
  }

  @override
  DeviceType get type => DeviceType.sensor;

  void onData(String data) {
    final elements = data.trim().split(RegExp(r'\s+'));
    if (elements.length < 5) {
      return;
    }
    final values = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'temperature': _finiteValue(elements[1]),
      'pressure': _finiteValue(elements[2]),
      'weight': _finiteValue(elements[3]),
      'weightFlow': _finiteValue(elements[4]),
    };

    _streamSubject.add(values);
  }

  double? _finiteValue(String value) {
    final parsed = double.tryParse(value);
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  @override
  Future<Map<String, dynamic>> execute(
    String commandId,
    Map<String, dynamic>? parameters,
  ) async {
    if (commandId == 'tare') {
      await _transport.writeCommand('tare');
      return {'status': 'ok'};
    }
    return {};
  }

  @override
  SensorInfo get info => SensorInfo(
    name: "SensorBasket",
    vendor: "DecentEspresso",
    dataChannels: [
      DataChannel(key: "timestamp", type: "string"),
      DataChannel(key: "temperature", type: "number", unit: "°C"),
      DataChannel(key: "pressure", type: "number", unit: "Bar"),
      DataChannel(key: "weight", type: "number", unit: "g"),
      DataChannel(key: "weightFlow", type: "number", unit: "g/s"),
    ],
    commands: [
      CommandDescriptor(
        id: 'tare',
        name: 'Tare',
        description: 'Tare sensor scale',
        paramsSchema: null,
        resultsSchema: null,
      ),
    ],
  );
}
