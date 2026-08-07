import 'dart:async';

import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';

/// `Sensor` adapter wrapping Bengle's internal milk-probe signals.
///
/// **Scaffolding** — real `Bengle` never emits on the probe streams
/// today (probe discovery + data transport is TBD with FW). This
/// adapter only carries data when wrapping a `MockBengle` (synthesised
/// during steam) or once FW lands. The adapter is created and
/// registered with `SensorController` by `BengleProbeBridge`.
///
/// Lifecycle is **probe-attached**, not machine-connected: the bridge
/// instantiates this when `probeAttached` flips `true` and removes it
/// when `false` (or when the machine disconnects).
class BengleMilkProbe implements Sensor {
  BengleMilkProbe({required BengleInterface bengle, String? deviceId})
    : _bengle = bengle,
      _deviceId = deviceId ?? '${_machineDeviceId(bengle)}-milkprobe';

  static String _machineDeviceId(BengleInterface bengle) =>
      (bengle as Device).deviceId;

  final BengleInterface _bengle;
  final String _deviceId;

  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.disconnected);
  final BehaviorSubject<Map<String, dynamic>> _data = BehaviorSubject();
  StreamSubscription<bool>? _attachedSub;
  StreamSubscription<double>? _tempSub;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

  @override
  TransportType get transportType => _bengle.transportType;

  @override
  String get name => 'Bengle Milk Probe';

  @override
  DeviceType get type => DeviceType.sensor;

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Stream<Map<String, dynamic>> get data => _data.stream;

  @override
  SensorInfo get info => SensorInfo(
    name: name,
    vendor: 'DecentEspresso',
    dataChannels: [
      DataChannel(key: 'timestamp', type: 'string'),
      DataChannel(key: 'temperature', type: 'number', unit: '°C'),
    ],
    commands: const [],
  );

  @override
  Future<Map<String, dynamic>> execute(
    String commandId,
    Map<String, dynamic>? parameters,
  ) async {
    return const {};
  }

  @override
  Future<void> onConnect() async {
    _attachedSub = _bengle.probeAttached.listen((attached) {
      if (_connectionState.isClosed) return;
      _connectionState.add(
        attached ? ConnectionState.connected : ConnectionState.disconnected,
      );
    });
    _tempSub = _bengle.probeTemperature.listen((celsius) {
      if (_data.isClosed) return;
      _data.add({
        'timestamp': DateTime.now().toIso8601String(),
        'temperature': celsius,
      });
    });
  }

  @override
  Future<void> disconnect() async {
    await _attachedSub?.cancel();
    _attachedSub = null;
    await _tempSub?.cancel();
    _tempSub = null;
    if (!_connectionState.isClosed) {
      _connectionState.add(ConnectionState.disconnected);
      await _connectionState.close();
    }
    if (!_data.isClosed) {
      await _data.close();
    }
  }
}
