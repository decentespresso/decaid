import 'dart:async';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

/// Fake [SerialTransport] that can drive [readStream], via [injectSerial], and
/// records every outbound [writeCommand] in [writes].
class FakeSerialTransport extends SerialTransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  final _readCtl = StreamController<String>.broadcast();

  final List<String> writes = [];

  @override
  String get id => 'fake-serial';
  @override
  String get name => 'FakeSerial';
  @override
  Stream<ConnectionState> get connectionState => _connState.stream;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<String> get readStream => _readCtl.stream;
  @override
  Stream<Uint8List> get rawStream => const Stream.empty();
  @override
  Future<void> writeHexCommand(Uint8List command) async {}
  @override
  Future<void> writeCommand(String command) async => writes.add(command);

  void injectSerial(String chunk) => _readCtl.add(chunk);

  @override
  Future<void> dispose() async {
    await _connState.close();
    await _readCtl.close();
  }
}
