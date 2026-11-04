import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/sensor/sensor_basket.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';

class _SerialTransport implements SerialTransport {
  @override
  final String id = 'sensor-basket';

  @override
  String get name => 'SensorBasket';

  @override
  TransportType get transportType => TransportType.serial;

  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);

  @override
  Stream<String> get readStream => const Stream.empty();

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> writeCommand(String command) async {}

  @override
  Future<void> writeHexCommand(Uint8List command) async {}
}

void main() {
  late SensorBasket sensor;

  setUp(() {
    sensor = SensorBasket(transport: _SerialTransport());
  });

  test('preserves channel alignment with repeated whitespace', () async {
    final next = sensor.data.first;
    sensor.onData('24 24.69 NaN  0.04 0.00 bat:4.28V ...');

    final snapshot = await next;
    expect(
      snapshot.keys,
      containsAll(['temperature', 'pressure', 'weight', 'weightFlow']),
    );
    expect(snapshot, containsPair('temperature', 24.69));
    expect(snapshot, containsPair('pressure', isNull));
    expect(snapshot, containsPair('weight', 0.04));
    expect(snapshot, containsPair('weightFlow', 0.00));
    expect(() => jsonEncode(snapshot), returnsNormally);
  });

  test(
    'normalizes non-finite channel readings to null in JSON snapshots',
    () async {
      for (final slot in [0, 1, 2, 3]) {
        for (final spelling in ['NaN', 'nan', 'Infinity', '-Infinity']) {
          final fields = ['24.69', '0.04', '0.00', '0.00'];
          fields[slot] = '$spelling ';
          final line = '24 ${fields.join(' ')} bat:4.28V chg:Y usb:Y 1 ms';
          final caseSensor = SensorBasket(transport: _SerialTransport());
          final next = caseSensor.data.first;
          caseSensor.onData(line);
          final snapshot = await next;
          final expected = <String, dynamic>{
            'temperature': 24.69,
            'pressure': 0.04,
            'weight': 0.00,
            'weightFlow': 0.00,
          };
          final keys = ['temperature', 'pressure', 'weight', 'weightFlow'];
          expected[keys[slot]] = null;
          expect(
            snapshot.keys,
            containsAll(['temperature', 'pressure', 'weight', 'weightFlow']),
          );
          expect(
            snapshot,
            containsPair('temperature', expected['temperature']),
          );
          expect(snapshot, containsPair('pressure', expected['pressure']));
          expect(snapshot, containsPair('weight', expected['weight']));
          expect(snapshot, containsPair('weightFlow', expected['weightFlow']));
          expect(jsonEncode(snapshot), isNot(contains('NaN')));
          expect(jsonEncode(snapshot), isNot(contains('Infinity')));
        }
      }
    },
  );
}
