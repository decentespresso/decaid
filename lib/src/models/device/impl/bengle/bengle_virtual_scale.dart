import 'dart:async';

import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

class BengleVirtualScale extends Scale {
  final BengleInterface _machine;

  BengleVirtualScale(this._machine);

  @override
  String get deviceId => 'bengle-internal-${_machine.deviceId}';

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

  @override
  TransportType get transportType => _machine.transportType;

  @override
  String get name => 'Bengle scale';

  @override
  DeviceType get type => DeviceType.scale;

  @override
  Stream<ConnectionState> get connectionState => _machine.connectionState;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _machine.weightSnapshot;

  @override
  Future<void> tare() => _machine.tareIntegratedScale();

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

  @override
  Future<void> onConnect() async {}

  @override
  Future<void> disconnect() async {}
}
