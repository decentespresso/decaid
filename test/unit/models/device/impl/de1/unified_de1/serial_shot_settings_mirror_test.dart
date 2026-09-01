import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

class _QuietSerialTransport extends SerialTransport {
  final _connectionState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  final input = StreamController<String>.broadcast(sync: true);
  final writes = <String>[];

  @override
  String get id => 'serial-mirror-test';

  @override
  String get name => 'Serial mirror test';

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

const _shotSettingsFrame = '[K]0100b4001e0050000000c8001400280239\n';

void main() {
  late _QuietSerialTransport serial;
  late UnifiedDe1Transport transport;

  setUp(() {
    serial = _QuietSerialTransport();
    transport = UnifiedDe1Transport(transport: serial);
  });

  tearDown(() async {
    await serial.dispose();
  });

  test('a serial connect seeds the subject from the local mirror', () async {
    await transport.connect();

    final frame = await transport.shotSettings.first.timeout(
      const Duration(seconds: 1),
    );
    expect(
      frame.buffer.asUint8List(),
      [0x00, 0x96, 0x1e, 0x4b, 0x32, 0x1e, 0x24, 0x5e, 0x00],
      reason: 'firmware defaults, since a serial machine never pushes K',
    );
    expect(
      serial.writes.where((w) => w == '<-K>'),
      isEmpty,
      reason:
          'no re-arm may be issued (the connect-time <+K> subscribe is expected)',
    );
  });

  test('a live K frame updates the mirror for the next connect', () async {
    await transport.connect();
    serial.input.add(_shotSettingsFrame);

    final live = await transport.shotSettings.first.timeout(
      const Duration(seconds: 1),
    );
    final liveBytes = live.buffer.asUint8List();

    await transport.disconnect();
    await transport.connect();

    final reseeded = await transport.shotSettings.first.timeout(
      const Duration(seconds: 1),
    );
    expect(reseeded.buffer.asUint8List(), liveBytes);
  });

  test('a local write updates the mirror for the next connect', () async {
    await transport.connect();
    final written = Uint8List.fromList([
      0x01,
      0x96,
      0x10,
      0x4b,
      0x32,
      0x1e,
      0x24,
      0x5e,
      0x00,
    ]);
    transport.recordLocalShotSettings(ByteData.sublistView(written));

    await transport.disconnect();
    await transport.connect();

    final reseeded = await transport.shotSettings.first.timeout(
      const Duration(seconds: 1),
    );
    expect(reseeded.buffer.asUint8List(), written);
  });

  test('a BLE connect never issues serial commands', () async {
    final ble = FakeBleTransport();
    final bleTransport = UnifiedDe1Transport(transport: ble);
    addTearDown(bleTransport.dispose);

    await bleTransport.connect();

    final frame = await bleTransport.shotSettings.first.timeout(
      const Duration(seconds: 1),
    );
    expect(frame.lengthInBytes, 20);
    expect(ble.writes, isEmpty);
  });
}
