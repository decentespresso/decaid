import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/atomheart/atomheart_scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

class _AtomheartTransport extends BLETransport {
  final BehaviorSubject<ConnectionState> states = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  Object? connectError;
  List<String> services = [AtomheartScale.serviceIdentifier.long];

  @override
  String get id => 'atomheart-test';

  @override
  String get name => 'Atomheart Eclair';

  @override
  Stream<ConnectionState> get connectionState => states.stream;

  @override
  Future<ConnectionState> getConnectionState() async => states.value;

  @override
  Future<void> connect() async {
    final error = connectError;
    if (error != null) throw error;
    states.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async => states.add(ConnectionState.disconnected);

  @override
  Future<List<String>> discoverServices() async => services;

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {}

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
  Future<void> dispose() async {}
}

void main() {
  late List<LogRecord> records;
  late Level previousLevel;

  setUp(() {
    records = [];
    previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(records.add);
  });

  tearDown(() {
    Logger.root.level = previousLevel;
    Logger.root.clearListeners();
  });

  test('logs the reason when the transport connect fails', () async {
    final transport = _AtomheartTransport()
      ..connectError = TimeoutException('connect timed out');
    final scale = AtomheartScale(transport: transport);

    await scale.onConnect();

    expect(await scale.connectionState.first, ConnectionState.disconnected);
    expect(
      records.where(
        (r) =>
            r.level >= Level.WARNING && r.message.contains('connect timed out'),
      ),
      isNotEmpty,
    );
  });

  test('logs the reason when the expected service is missing', () async {
    final transport = _AtomheartTransport()..services = ['0000180a-0000'];
    final scale = AtomheartScale(transport: transport);

    await scale.onConnect();

    expect(await scale.connectionState.first, ConnectionState.disconnected);
    expect(
      records.where(
        (r) =>
            r.level >= Level.WARNING && r.message.contains('Expected service'),
      ),
      isNotEmpty,
    );
  });
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  @override
  String toString() => message;
}
