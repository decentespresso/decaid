import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/atomheart/atomheart_scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

class _RecordingTransport extends BLETransport {
  final BehaviorSubject<ConnectionState> states = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final Completer<void> firstSubscription = Completer<void>();
  final List<({String service, String characteristic, List<int> data})> writes =
      [];

  List<String> services = [AtomheartScale.serviceIdentifier.long];
  Object? connectError;
  Object? discoveryError;
  Object? subscriptionError;
  int subscribeCalls = 0;
  int resetSubscriptionCalls = 0;
  int disconnectCalls = 0;
  String? subscribedService;
  String? subscribedCharacteristic;
  void Function(Uint8List)? notificationCallback;

  @override
  String get id => 'eclair-test';

  @override
  String get name => 'Eclair';

  @override
  Stream<ConnectionState> get connectionState => states.stream;

  @override
  Future<ConnectionState> getConnectionState() async => states.value;

  @override
  Future<void> connect() async {
    if (connectError case final error?) throw error;
    states.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    states.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async {
    if (discoveryError case final error?) throw error;
    return services;
  }

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    subscribeCalls++;
    _recordSubscription(serviceUUID, characteristicUUID, callback);
  }

  @override
  Future<void> resetSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    resetSubscriptionCalls++;
    _recordSubscription(serviceUUID, characteristicUUID, callback);
  }

  void _recordSubscription(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) {
    if (!firstSubscription.isCompleted) firstSubscription.complete();
    if (subscriptionError case final error?) throw error;
    subscribedService = serviceUUID;
    subscribedCharacteristic = characteristicUUID;
    notificationCallback = callback;
  }

  void emit(List<int> data) => notificationCallback!(Uint8List.fromList(data));

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    writes.add((
      service: serviceUUID,
      characteristic: characteristicUUID,
      data: data.toList(),
    ));
  }

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> dispose() async {
    await states.close();
  }
}

void main() {
  test('uses the current Eclair GATT contract', () async {
    expect(
      AtomheartScale.serviceIdentifier.long,
      'b905eaea-2e63-0e04-7582-7913f10d8f81',
    );
    expect(
      AtomheartScale.dataCharacteristic.long,
      'ad736c5f-bbc9-1f96-d304-cb5d5f41e160',
    );
    expect(
      AtomheartScale.commandCharacteristic.long,
      '4f9a45ba-8e1b-4e07-e157-0814d393b968',
    );

    final transport = _RecordingTransport();
    final scale = AtomheartScale(
      transport: transport,
      notificationTimeout: const Duration(seconds: 1),
    );
    final connection = scale.onConnect();

    await transport.firstSubscription.future;
    expect(transport.subscribedService, AtomheartScale.serviceIdentifier.long);
    expect(
      transport.subscribedCharacteristic,
      AtomheartScale.dataCharacteristic.long,
    );

    transport.emit(_weightFrame(weightMg: 1500, timerMs: 5000));
    await connection;
    await transport.dispose();
  });

  test('stays connecting until the first valid weight frame', () async {
    final transport = _RecordingTransport();
    final scale = AtomheartScale(
      transport: transport,
      notificationTimeout: const Duration(seconds: 1),
    );
    final snapshot = scale.currentSnapshot.first;
    final connection = scale.onConnect();

    await transport.firstSubscription.future;
    expect(await scale.connectionState.first, ConnectionState.connecting);

    transport.emit(_weightFrame(weightMg: 1500, timerMs: 5000));
    await connection;

    expect(await scale.connectionState.first, ConnectionState.connected);
    expect((await snapshot).weight, closeTo(1.5, 0.001));
    await transport.dispose();
  });

  test('silent notifications retry twice and then disconnect', () async {
    final transport = _RecordingTransport();
    final scale = AtomheartScale(
      transport: transport,
      notificationTimeout: const Duration(milliseconds: 5),
    );

    await scale.onConnect();

    expect(transport.subscribeCalls, 1);
    expect(transport.resetSubscriptionCalls, 2);
    expect(transport.disconnectCalls, 1);
    expect(await scale.connectionState.first, ConnectionState.disconnected);
    await transport.dispose();
  });

  for (final stage in ['connect', 'service discovery', 'subscription']) {
    test('$stage failure ends disconnected', () async {
      final transport = _RecordingTransport();
      switch (stage) {
        case 'connect':
          transport.connectError = StateError('connect failed');
        case 'service discovery':
          transport.discoveryError = StateError('discovery failed');
        case 'subscription':
          transport.subscriptionError = StateError('subscription failed');
      }
      final scale = AtomheartScale(
        transport: transport,
        notificationTimeout: const Duration(milliseconds: 5),
      );

      await scale.onConnect();

      expect(await scale.connectionState.first, ConnectionState.disconnected);
      expect(transport.disconnectCalls, 1);
      await transport.dispose();
    });
  }

  test(
    'writes current tare and timer opcodes to the command characteristic',
    () async {
      final transport = _RecordingTransport();
      final scale = AtomheartScale(transport: transport);

      await scale.tare();
      await scale.resetTimer();
      await scale.startTimer();
      await scale.stopTimer();

      expect(transport.writes.map((write) => write.service).toSet(), {
        AtomheartScale.serviceIdentifier.long,
      });
      expect(transport.writes.map((write) => write.characteristic).toSet(), {
        AtomheartScale.commandCharacteristic.long,
      });
      expect(transport.writes.map((write) => write.data).toList(), [
        [0x54, 0x01, 0x01],
        [0x52, 0x01, 0x01],
        [0x53, 0x01, 0x01],
        [0x45, 0x01, 0x01],
      ]);
      await transport.dispose();
    },
  );
}

List<int> _weightFrame({required int weightMg, required int timerMs}) {
  final payload = ByteData(8)
    ..setInt32(0, weightMg, Endian.little)
    ..setUint32(4, timerMs, Endian.little);
  final bytes = payload.buffer.asUint8List();
  var checksum = 0;
  for (final byte in bytes) {
    checksum ^= byte;
  }
  return [0x57, ...bytes, checksum & 0xff];
}
