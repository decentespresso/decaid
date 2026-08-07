import 'dart:typed_data';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';

abstract class BLETransport extends DataTransport {
  @override
  TransportType get transportType => TransportType.ble;

  Future<List<String>> discoverServices();

  Future<ConnectionState> getConnectionState();

  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  );

  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) => subscribe(serviceUUID, characteristicUUID, callback);

  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  });

  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  });

  Future<void> setTransportPriority(bool prioritized);
}
