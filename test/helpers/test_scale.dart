import 'dart:async';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';

class TestScale implements Scale {
  @override
  final String deviceId;

  @override
  final String name;

  final BehaviorSubject<ConnectionState> _connectionState;

  TestScale({
    this.deviceId = 'test-scale',
    this.name = 'Mock Scale',
    ConnectionState initialState = ConnectionState.connected,
  }) : _connectionState = BehaviorSubject.seeded(initialState);

  @override
  DeviceType get type => DeviceType.scale;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  void setConnectionState(ConnectionState state) {
    _connectionState.add(state);
  }

  final BehaviorSubject<ScaleSnapshot> _snapshotSubject = BehaviorSubject();

  void emitSnapshot(ScaleSnapshot snapshot) {
    _snapshotSubject.add(snapshot);
  }

  void dispose() {
    _connectionState.close();
    _snapshotSubject.close();
  }

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshotSubject.stream;

  @override
  Future<void> onConnect() async {}

  @override
  Future<void> disconnect() async {}

  int tareCallCount = 0;

  @override
  Future<void> tare() async {
    tareCallCount++;
  }

  @override
  Future<void> sleepDisplay() async {}

  @override
  Future<void> wakeDisplay() async {}

  @override
  Future<void> startTimer() async {}

  @override
  Future<void> stopTimer() async {}

  @override
  Future<void> resetTimer() async {}
}
