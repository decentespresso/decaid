import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/services/ble/read_only_ble_transport.dart';

void main() {
  test('delegates reads and connection lifecycle', () async {
    final delegate = _RecordingBleTransport();
    final transport = ReadOnlyBleTransport(delegate);

    await transport.connect();
    expect(await transport.discoverServices(), ['service']);
    expect(
      await transport.read('service', 'characteristic'),
      Uint8List.fromList([1, 2, 3]),
    );
    await transport.setTransportPriority(true);
    await transport.disconnect();
    await transport.dispose();

    expect(delegate.calls, [
      'connect',
      'discoverServices',
      'read',
      'setTransportPriority:true',
      'disconnect',
      'dispose',
    ]);
    expect(transport.id, delegate.id);
    expect(transport.name, delegate.name);
    expect(transport.transportType, TransportType.ble);
  });

  test('blocks writes without invoking the delegate', () async {
    final delegate = _RecordingBleTransport();
    final transport = ReadOnlyBleTransport(delegate);

    await transport.write(
      'service',
      'characteristic',
      Uint8List.fromList([4, 5, 6]),
      withResponse: false,
      timeout: const Duration(seconds: 1),
    );

    expect(delegate.calls, isEmpty);
    expect(delegate.writes, isEmpty);
  });

  test('delegates writes explicitly classified as read-only queries', () async {
    final delegate = _RecordingBleTransport();
    final transport = ReadOnlyBleTransport(
      delegate,
      allowWrite: (service, characteristic, data) =>
          service == 'A000' && characteristic == 'A005' && data.length == 20,
    );
    final query = Uint8List(20);

    await transport.write('A000', 'A005', query);
    await transport.write('A000', 'A006', query);

    expect(delegate.calls, ['write']);
    expect(delegate.writes, [query]);
  });

  test('delegates subscription operations', () async {
    final delegate = _RecordingBleTransport();
    final transport = ReadOnlyBleTransport(delegate);
    void callback(Uint8List _) {}

    await transport.subscribe('service', 'characteristic', callback);
    await transport.resetSubscription('service', 'characteristic', callback);

    expect(delegate.calls, ['subscribe', 'resetSubscription']);
  });
}

class _RecordingBleTransport extends BLETransport {
  final calls = <String>[];
  final writes = <Uint8List>[];

  @override
  String get id => 'device-id';

  @override
  String get name => 'device-name';

  @override
  Stream<ConnectionState> get connectionState =>
      const Stream<ConnectionState>.empty();

  @override
  Future<void> connect() async => calls.add('connect');

  @override
  Future<void> disconnect() async => calls.add('disconnect');

  @override
  Future<void> dispose() async => calls.add('dispose');

  @override
  Future<List<String>> discoverServices() async {
    calls.add('discoverServices');
    return ['service'];
  }

  @override
  Future<ConnectionState> getConnectionState() async =>
      ConnectionState.connected;

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async => calls.add('subscribe');

  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async => calls.add('resetSubscription');

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async {
    calls.add('read');
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    calls.add('write');
    writes.add(data);
  }

  @override
  Future<void> setTransportPriority(bool prioritized) async =>
      calls.add('setTransportPriority:$prioritized');
}
