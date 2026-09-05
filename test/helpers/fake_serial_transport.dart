import 'dart:async';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

/// Inbound-capable fake [SerialTransport] for transport-level tests.
///
/// The repo's older recording fake is write-only (`readStream` never emits),
/// so it can't exercise the serial RX parser. This one drives [readStream]
/// from a broadcast controller via [injectSerial] and records every outbound
/// [writeCommand] string in [writes] — the serial analogue of
/// `FakeBleTransport`'s `writes` capture. Added for the serial-transport work
/// serial-parity suite.
class FakeSerialTransport extends SerialTransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  final _readCtl = StreamController<String>.broadcast();

  /// Outbound `writeCommand` strings, in order (e.g. `<+N>`, `<-M>`).
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

  /// Feed a raw serial chunk into the transport's input parser.
  void injectSerial(String chunk) => _readCtl.add(chunk);

  @override
  Future<void> dispose() async {
    await _connState.close();
    await _readCtl.close();
  }
}
