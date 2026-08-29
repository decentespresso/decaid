import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';

/// A transport boundary for live validation that permits observation but
/// prevents state-changing BLE writes from reaching the device.
typedef ReadOnlyWritePolicy =
    bool Function(
      String serviceUUID,
      String characteristicUUID,
      Uint8List data,
    );

class ReadOnlyBleTransport extends BLETransport {
  ReadOnlyBleTransport(this._delegate, {ReadOnlyWritePolicy? allowWrite})
    : _allowWrite = allowWrite;

  final BLETransport _delegate;
  final ReadOnlyWritePolicy? _allowWrite;
  final Logger _log = Logger('ReadOnlyBleTransport');

  @override
  String get id => _delegate.id;

  @override
  String get name => _delegate.name;

  @override
  Stream<ConnectionState> get connectionState => _delegate.connectionState;

  @override
  Future<void> connect() => _delegate.connect();

  @override
  Future<void> disconnect() => _delegate.disconnect();

  @override
  Future<void> dispose() => _delegate.dispose();

  @override
  Future<List<String>> discoverServices() => _delegate.discoverServices();

  @override
  Future<ConnectionState> getConnectionState() =>
      _delegate.getConnectionState();

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) => _delegate.subscribe(serviceUUID, characteristicUUID, callback);

  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) => _delegate.resetSubscription(serviceUUID, characteristicUUID, callback);

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) => _delegate.read(serviceUUID, characteristicUUID, timeout: timeout);

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (_allowWrite?.call(serviceUUID, characteristicUUID, data) ?? false) {
      _log.info(
        'READ_ONLY_ALLOWED_BLE_QUERY '
        'service=$serviceUUID characteristic=$characteristicUUID '
        'bytes=${data.length} withResponse=$withResponse',
      );
      return _delegate.write(
        serviceUUID,
        characteristicUUID,
        data,
        withResponse: withResponse,
        timeout: timeout,
      );
    }
    _log.warning(
      'READ_ONLY_BLOCKED_BLE_WRITE '
      'service=$serviceUUID characteristic=$characteristicUUID '
      'bytes=${data.length} withResponse=$withResponse',
    );
  }

  @override
  Future<void> setTransportPriority(bool prioritized) =>
      _delegate.setTransportPriority(prioritized);
}
