import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/errors.dart';

class BleAdmissionTransport extends BLETransport {
  final BLETransport transport;
  final Object Function() reserve;
  final void Function(Object) release;
  Object? _claim;
  StreamSubscription<ConnectionState>? _subscription;
  Future<void>? _closing;
  bool _disposed = false;

  BleAdmissionTransport({
    required this.transport,
    required this.reserve,
    required this.release,
  });

  @override
  String get id => transport.id;
  @override
  String get name => transport.name;
  @override
  Stream<ConnectionState> get connectionState => transport.connectionState;

  @override
  Future<void> connect() async {
    await _closing;
    if (_disposed) throw StateError('BLE candidate disposed');
    _claim ??= reserve();
    try {
      await transport.connect();
      if (_disposed) throw StateError('BLE candidate disposed');
      _subscription ??= transport.connectionState.listen((state) {
        if (state == ConnectionState.disconnected && _claim != null) {
          unawaited(
            disconnectConfirmed().catchError((Object error) {
              Logger(
                'BleAdmissionTransport',
              ).warning('Native BLE ownership retained: $id', error);
            }),
          );
        }
      });
    } catch (_) {
      unawaited(
        disconnectConfirmed().catchError((Object error) {
          Logger(
            'BleAdmissionTransport',
          ).warning('Failed connect ownership retained: $id', error);
        }),
      );
      rethrow;
    }
  }

  @override
  Future<void> disconnect() => disconnectConfirmed();

  @override
  Future<void> disconnectConfirmed() {
    if (_claim == null) return Future.value();
    return _closing ??= _close().whenComplete(() => _closing = null);
  }

  Future<void> _close() async {
    await transport.disconnectConfirmed();
    await _subscription?.cancel();
    _subscription = null;
    final claim = _claim;
    _claim = null;
    if (claim != null) release(claim);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnectConfirmed();
    await _subscription?.cancel();
    _subscription = null;
    await transport.dispose();
  }

  @override
  Future<ConnectionState> getConnectionState() =>
      transport.getConnectionState();
  Future<T> _owned<T>(Future<T> Function() operation) async {
    if (_claim == null || _disposed) {
      throw const DeviceNotConnectedException.unknown();
    }
    return operation();
  }

  @override
  Future<List<String>> discoverServices() => _owned(transport.discoverServices);
  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) => _owned(
    () => transport.read(serviceUUID, characteristicUUID, timeout: timeout),
  );
  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) => _owned(
    () => transport.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    ),
  );
  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) => _owned(
    () => transport.subscribe(serviceUUID, characteristicUUID, callback),
  );
  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) => _owned(
    () =>
        transport.resetSubscription(serviceUUID, characteristicUUID, callback),
  );
  @override
  Future<void> unsubscribe(String serviceUUID, String characteristicUUID) =>
      _owned(() => transport.unsubscribe(serviceUUID, characteristicUUID));
  @override
  Future<void> setTransportPriority(bool prioritized) =>
      _owned(() => transport.setTransportPriority(prioritized));
}
