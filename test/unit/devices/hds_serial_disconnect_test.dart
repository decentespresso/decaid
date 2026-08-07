import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale_serial.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

class MockSerialTransport implements SerialTransport {
  final BehaviorSubject<ConnectionState> _connectionSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);

  @override
  Stream<ConnectionState> get connectionState => _connectionSubject.stream;

  @override
  String get id => 'mock-serial';

  @override
  String get name => 'MockSerial';

  @override
  TransportType get transportType => TransportType.serial;

  final StreamController<Uint8List> _rawController =
      StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get rawStream => _rawController.stream;

  final StreamController<String> _readController =
      StreamController<String>.broadcast();
  @override
  Stream<String> get readStream => _readController.stream;

  bool connectCalled = false;
  bool disconnectCalled = false;
  List<Uint8List> writtenHexCommands = [];

  @override
  Future<void> connect() async {
    connectCalled = true;
    _connectionSubject.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
    _connectionSubject.add(ConnectionState.disconnected);
  }

  @override
  Future<void> writeCommand(String command) async {}

  @override
  Future<void> writeHexCommand(Uint8List command) async {
    writtenHexCommands.add(command);
  }

  /// Push raw bytes into the rawStream (simulates data from device).
  void emitRawData(Uint8List data) {
    _rawController.add(data);
  }

  @override
  Future<void> dispose() async {
    _connectionSubject.close();
    _rawController.close();
    _readController.close();
  }
}

void main() {
  late MockSerialTransport transport;
  late HDSSerial hds;

  setUp(() {
    transport = MockSerialTransport();
    hds = HDSSerial(transport: transport);
  });

  tearDown(() {
    transport.dispose();
  });

  group('HDSSerial.disconnect()', () {
    test('does not throw when called before onConnect', () async {
      await expectLater(hds.disconnect(), completes);
    });

    test('calls transport.disconnect() even without prior onConnect', () async {
      await hds.disconnect();
      expect(transport.disconnectCalled, isTrue);
    });

    test('emits disconnected state', () async {
      await hds.disconnect();
      final state = await hds.connectionState.first;
      expect(state, ConnectionState.disconnected);
    });

    test('is safe to call twice (re-entrant guard)', () async {
      await hds.disconnect();
      await expectLater(hds.disconnect(), completes);
    });

    test('calls transport.disconnect() after onConnect', () async {
      await hds.onConnect();
      await hds.disconnect();
      expect(transport.disconnectCalled, isTrue);
    });
  });
}
