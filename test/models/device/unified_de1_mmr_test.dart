import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/errors.dart';

class _QuietSerialTransport extends SerialTransport {
  // Stream.multi replays the connected state to each listener; a seeded
  // rxdart BehaviorSubject cannot deliver its seed inside fake_async.
  @override
  String get id => 'quiet-serial-de1';

  @override
  String get name => 'QuietSerialDe1';

  @override
  Stream<ConnectionState> get connectionState => Stream.multi((controller) {
    controller.add(ConnectionState.connected);
    controller.close();
  });

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Stream<String> get readStream => const Stream.empty();

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();

  @override
  Future<void> writeHexCommand(Uint8List command) async {}

  @override
  Future<void> writeCommand(String command) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  group('_mmrRead timeout (comms-harden #2)', () {
    late _QuietSerialTransport transport;
    late UnifiedDe1 de1;

    setUp(() {
      transport = _QuietSerialTransport();
      de1 = UnifiedDe1(transport: transport);
    });

    tearDown(() {
      transport.dispose();
    });

    test('throws MmrTimeoutException when no matching response arrives', () {
      fakeAsync((async) {
        Object? caught;
        captureError(de1.getSteamFlow(), (e) => caught = e);
        // Full production durations: 3 attempts x 4s timeout + 2 x 300ms
        // retry settle, verified virtually instead of in real time.
        async.elapse(const Duration(seconds: 13));
        expect(caught, isA<MmrTimeoutException>());
      });
    });
  });
}

Future<void> captureError(
  Future<double> future,
  void Function(Object) onError,
) async {
  try {
    await future;
  } catch (e) {
    onError(e);
  }
}
