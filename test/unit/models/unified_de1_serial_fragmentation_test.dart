import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';

import '../../helpers/fake_serial_transport.dart';

void main() {
  final frames = <Endpoint, List<int>>{
    Endpoint.stateInfo: [4, 0],
    Endpoint.shotSample: List.generate(19, (i) => i),
    Endpoint.bengleShotSample: List.generate(28, (i) => i + 20),
    Endpoint.readFromMMR: [3, 0x80, 0x38, 0x04, 1, 2, 3, 4],
    Endpoint.waterLevels: [0, 42, 0, 12],
  };
  final input =
      '${frames.entries.map((frame) {
        final hex = frame.value.map((b) => b.toRadixString(16).padLeft(2, '0'));
        return '[${frame.key.representation}]${hex.join()}';
      }).join('\n')}\r\n';

  late FakeSerialTransport serial;
  late UnifiedDe1Transport transport;
  late List<(Endpoint, List<int>)> notifications;

  setUp(() async {
    serial = FakeSerialTransport();
    notifications = [];
    transport = UnifiedDe1Transport(
      transport: serial,
      onNotification: (endpoint, bytes) {
        notifications.add((endpoint, Uint8List.fromList(bytes)));
      },
    );
    await transport.connect();
  });

  tearDown(() => transport.dispose());

  test('preserves every frame across every possible two-chunk split', () async {
    for (var split = 1; split < input.length; split++) {
      notifications.clear();
      serial.injectSerial(input.substring(0, split));
      await pumpEventQueue();
      serial.injectSerial(input.substring(split));
      await pumpEventQueue();
      expect(
        notifications.map((n) => n.$1),
        frames.keys,
        reason: 'split $split',
      );
      expect(
        notifications.map((n) => n.$2),
        frames.values,
        reason: 'split $split',
      );
    }
  });

  test('preserves frames delivered one byte at a time', () async {
    for (final byte in input.split('')) {
      serial.injectSerial(byte);
      await pumpEventQueue();
    }
    expect(notifications.map((n) => n.$1), frames.keys);
    expect(notifications.map((n) => n.$2), frames.values);
  });
}
