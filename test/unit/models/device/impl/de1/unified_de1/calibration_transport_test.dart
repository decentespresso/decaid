import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/calibration_codec.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

class _FakeSerialTransport extends SerialTransport {
  final _connectionState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  final input = StreamController<String>.broadcast(sync: true);
  final writes = <String>[];

  @override
  String get id => 'serial-cal-test';

  @override
  String get name => 'Serial cal test';

  @override
  Stream<ConnectionState> get connectionState => _connectionState.stream;

  @override
  Stream<String> get readStream => input.stream;

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> dispose() async {
    if (!input.isClosed) await input.close();
    if (!_connectionState.isClosed) await _connectionState.close();
  }

  @override
  Future<void> writeCommand(String command) async {
    writes.add(command);
  }

  @override
  Future<void> writeHexCommand(Uint8List command) async {}
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('BLE', () {
    test('connect subscribes to the A012 calibration characteristic', () async {
      final ble = FakeBleTransport();
      final transport = UnifiedDe1Transport(transport: ble);
      addTearDown(transport.dispose);

      await transport.connect();

      expect(ble.subscribers.containsKey(Endpoint.calibration.uuid), isTrue);
    });

    test('A012 notifications flow to the calibration stream', () async {
      final ble = FakeBleTransport();
      final transport = UnifiedDe1Transport(transport: ble);
      addTearDown(transport.dispose);
      await transport.connect();

      final received = <Uint8List>[];
      final sub = transport.calibration.listen(
        (d) => received.add(d.buffer.asUint8List()),
      );
      addTearDown(sub.cancel);

      final packet = De1CalibrationCodec.encodeRead(
        De1CalibrationTarget.flow,
        factory: false,
      );
      ble.emitNotification(Endpoint.calibration, packet);

      await pumpEventQueue();
      expect(received, [packet]);
    });

    test('short calibration frames are dropped', () async {
      final ble = FakeBleTransport();
      final transport = UnifiedDe1Transport(transport: ble);
      addTearDown(transport.dispose);
      await transport.connect();

      final received = <Uint8List>[];
      final sub = transport.calibration.listen(
        (d) => received.add(d.buffer.asUint8List()),
      );
      addTearDown(sub.cancel);

      ble.emitNotification(Endpoint.calibration, Uint8List(4));

      await pumpEventQueue();
      expect(received, isEmpty);
    });

    test('dispose closes the calibration stream', () async {
      final ble = FakeBleTransport();
      final transport = UnifiedDe1Transport(transport: ble);
      await transport.connect();

      var done = false;
      final sub = transport.calibration.listen(
        (_) {},
        onDone: () => done = true,
      );
      await transport.dispose();
      await sub.cancel();

      expect(done, isTrue);
    });
  });

  group('serial', () {
    test(
      'connect enables calibration notifications and disconnect disables',
      () async {
        final serial = _FakeSerialTransport();
        final transport = UnifiedDe1Transport(transport: serial);
        addTearDown(transport.dispose);

        await transport.connect();
        expect(serial.writes, contains('<+R>'));

        serial.writes.clear();
        await transport.disconnect();
        expect(serial.writes, contains('<-R>'));
      },
    );

    test('[R] frames flow to the calibration stream', () async {
      final serial = _FakeSerialTransport();
      final transport = UnifiedDe1Transport(transport: serial);
      addTearDown(transport.dispose);
      await transport.connect();

      final received = <Uint8List>[];
      final sub = transport.calibration.listen(
        (d) => received.add(d.buffer.asUint8List()),
      );
      addTearDown(sub.cancel);

      final packet = De1CalibrationCodec.encodeRead(
        De1CalibrationTarget.pressure,
        factory: true,
      );
      serial.input.add('[R]${_hex(packet)}\n');

      await pumpEventQueue();
      expect(received, [packet]);
    });

    test('calibration read resolves from the calibration stream', () async {
      final serial = _FakeSerialTransport();
      final transport = UnifiedDe1Transport(transport: serial);
      addTearDown(transport.dispose);
      await transport.connect();

      final packet = De1CalibrationCodec.encodeRead(
        De1CalibrationTarget.flow,
        factory: false,
      );
      final read = transport.read(
        Endpoint.calibration,
        timeout: const Duration(milliseconds: 100),
      );
      await pumpEventQueue();
      serial.input.add('[R]${_hex(packet)}\n');

      final result = await read;
      expect(result.buffer.asUint8List(), packet);
    });
  });
}
