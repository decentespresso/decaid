import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/eureka/eureka_scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

class _MockEurekaBleTransport extends BLETransport {
  _MockEurekaBleTransport({required this.serviceUUIDs});

  final List<String> serviceUUIDs;
  final BehaviorSubject<ConnectionState> _connectionState =
      BehaviorSubject.seeded(ConnectionState.discovered);
  final List<(String, String)> reads = [];
  final List<(String, String)> subscriptions = [];

  @override
  String get id => 'AA:BB:CC:DD:EE:FF';

  @override
  String get name => 'Solo Barista';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Future<ConnectionState> getConnectionState() async => _connectionState.value;

  @override
  Future<void> connect() async {
    _connectionState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => serviceUUIDs;

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async {
    reads.add((serviceUUID, characteristicUUID));
    return Uint8List.fromList([50]);
  }

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    subscriptions.add((serviceUUID, characteristicUUID));
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {}

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> dispose() async {
    await _connectionState.close();
  }
}

void main() {
  test(
    'scale without a battery service connects and skips the battery read',
    () async {
      final transport = _MockEurekaBleTransport(
        serviceUUIDs: [EurekaScale.serviceIdentifier.long],
      );
      final scale = EurekaScale(transport: transport);
      final states = <ConnectionState>[];
      final subscription = scale.connectionState.listen(states.add);

      await scale.onConnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        transport.subscriptions,
        contains((
          EurekaScale.serviceIdentifier.long,
          EurekaScale.dataCharacteristic.long,
        )),
      );
      expect(transport.reads, isEmpty);
      expect(states.last, ConnectionState.connected);

      await subscription.cancel();
      await transport.dispose();
    },
  );

  test('scale with a battery service still reads the battery level', () async {
    final transport = _MockEurekaBleTransport(
      serviceUUIDs: [
        EurekaScale.serviceIdentifier.long,
        EurekaScale.batteryService.long,
      ],
    );
    final scale = EurekaScale(transport: transport);

    await scale.onConnect();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(
      transport.reads,
      contains((
        EurekaScale.batteryService.long,
        EurekaScale.batteryCharacteristic.long,
      )),
    );

    await transport.dispose();
  });
}
