import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

class _PrimeSerialTransport extends SerialTransport {
  final _connectionState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  final input = StreamController<String>.broadcast(sync: true);
  final writes = <String>[];
  void Function(String command)? onWrite;
  Completer<void>? writeGate;

  void emitDisconnected() {
    _connectionState.add(ConnectionState.disconnected);
  }

  @override
  String get id => 'serial-prime-test';

  @override
  String get name => 'Serial prime test';

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
    onWrite?.call(command);
    final gate = writeGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> writeHexCommand(Uint8List command) async {}
}

const _primeTimeout = Duration(milliseconds: 40);
const _primeBackoff = Duration(milliseconds: 10);
const _primeRetries = 2;

const _shotSettingsFrame = '[K]0100b4001e0050000000c8001400280239\n';

void main() {
  late _PrimeSerialTransport serial;
  late UnifiedDe1Transport transport;

  UnifiedDe1Transport buildTransport(DataTransport port) => UnifiedDe1Transport(
    transport: port,
    shotSettingsPrimeTimeout: _primeTimeout,
    shotSettingsPrimeBackoff: _primeBackoff,
    shotSettingsPrimeRetries: _primeRetries,
  );

  List<String> rearmWrites(List<String> writes) =>
      writes.where((w) => w == '<-K>' || w == '<+K>').toList();

  bool hasRearm(List<String> writes) {
    for (var i = 0; i < writes.length; i++) {
      if (writes[i] == '<-K>' && writes.sublist(i + 1).contains('<+K>')) {
        return true;
      }
    }
    return false;
  }

  setUp(() {
    serial = _PrimeSerialTransport();
    transport = buildTransport(serial);
  });

  tearDown(() async {
    await serial.dispose();
  });

  test('a frame from the connect-time subscribe needs no re-arm', () async {
    await transport.connect();
    serial.writes.clear();
    serial.input.add(_shotSettingsFrame);

    await transport.shotSettingsPrimed;

    expect(rearmWrites(serial.writes), isEmpty);
    expect(
      await transport.shotSettings.first.timeout(_primeTimeout),
      isNotNull,
    );
  });

  test('a missing frame re-arms the endpoint and recovers', () async {
    serial.onWrite = (command) {
      if (command == '<+K>' && serial.writes.contains('<-K>')) {
        scheduleMicrotask(() => serial.input.add(_shotSettingsFrame));
      }
    };

    await transport.connect();
    serial.writes.clear();

    await transport.shotSettingsPrimed;

    expect(rearmWrites(serial.writes), ['<-K>', '<+K>']);
    expect(
      await transport.shotSettings.first.timeout(_primeTimeout),
      isNotNull,
    );
  });

  test('a DE1 that never answers stops after the configured retries', () async {
    await transport.connect();
    serial.writes.clear();

    await transport.shotSettingsPrimed;

    expect(rearmWrites(serial.writes), ['<-K>', '<+K>', '<-K>', '<+K>']);
  });

  test('disconnect during priming abandons it', () async {
    await transport.connect();
    serial.writes.clear();
    serial.emitDisconnected();

    await transport.shotSettingsPrimed;

    expect(rearmWrites(serial.writes), isEmpty);
  });

  test('an explicit disconnect during the prime wait never re-arms', () async {
    await transport.connect();
    serial.writes.clear();

    final gate = Completer<void>();
    serial.writeGate = gate;
    final disconnectFuture = transport.disconnect();

    // Teardown is stalled on its first unsubscribe write, so any <-K> that
    // appears while it is stalled can only be a prime re-arm, not the
    // teardown's own <-K> unsubscribe.
    await Future<void>.delayed(_primeTimeout * 2);
    expect(
      serial.writes.where((w) => w == '<-K>'),
      isEmpty,
      reason: 'no re-arm may be issued after teardown has begun',
    );

    gate.complete();
    serial.writeGate = null;
    await disconnectFuture;

    await transport.shotSettingsPrimed;
    expect(
      hasRearm(serial.writes),
      isFalse,
      reason: 'a re-arm must not survive the teardown window',
    );
  });

  test('a BLE transport never starts serial priming', () async {
    final ble = FakeBleTransport();
    final bleTransport = buildTransport(ble);
    addTearDown(bleTransport.dispose);

    await bleTransport.connect();
    await bleTransport.shotSettingsPrimed;

    expect(ble.writes, isEmpty);
  });
}
