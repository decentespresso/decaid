import 'dart:async';

import 'package:reaprime/src/models/device/device.dart';

enum TransportType { ble, serial, wifi, unknown }

abstract class DataTransport {
  String get id;
  String get name;

  TransportType get transportType;

  Stream<ConnectionState> get connectionState;

  Future<void> connect();

  Future<void> disconnect();

  Future<void> dispose();
}
