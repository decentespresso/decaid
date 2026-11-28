import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/calibration_codec.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  test('unexpected BLE loss ends listeners and clears water replay', () async {
    final ble = FakeBleTransport();
    final transport = UnifiedDe1Transport(transport: ble);
    addTearDown(transport.dispose);
    await transport.connect();
    final oldValues = <ByteData>[];
    var ended = false;
    final old = transport.waterLevels.listen(
      oldValues.add,
      onDone: () => ended = true,
    );
    final stale = ble.subscribers[Endpoint.waterLevels.uuid]!;
    ble.emitNotification(Endpoint.waterLevels, [0, 42, 0, 12]);
    await pumpEventQueue();
    ble.emitConnectionState(ConnectionState.disconnected);
    await pumpEventQueue();
    expect(ended, isTrue);

    ble.emitConnectionState(ConnectionState.connected);
    await transport.connect();
    final currentValues = <ByteData>[];
    final current = transport.waterLevels.listen(currentValues.add);
    var readCompleted = false;
    final read = transport.waterLevels.first.then((data) {
      readCompleted = true;
      return data;
    });
    stale(Uint8List.fromList([0, 43, 0, 12]));
    await pumpEventQueue();
    expect(currentValues, isEmpty);
    expect(readCompleted, isFalse);
    ble.emitNotification(Endpoint.waterLevels, [0, 44, 0, 12]);
    expect((await read).getUint16(0), 44);
    await pumpEventQueue();
    expect(oldValues, hasLength(1));
    expect(currentValues, hasLength(1));
    await old.cancel();
    await current.cancel();
  });

  test('retired calibration callbacks cannot enter a new session or disposed subject', () async {
    final ble = FakeBleTransport();
    final transport = UnifiedDe1Transport(transport: ble);
    await transport.connect();
    final stale = ble.subscribers[Endpoint.calibration.uuid]!;
    await transport.disconnect();
    await transport.connect();
    final values = <ByteData>[];
    final subscription = transport.calibration.listen(values.add);
    stale(Uint8List(De1CalibrationCodec.packetLength));
    await pumpEventQueue();
    expect(values, isEmpty);
    ble.emitNotification(
      Endpoint.calibration,
      Uint8List(De1CalibrationCodec.packetLength),
    );
    await pumpEventQueue();
    expect(values, hasLength(1));
    final active = ble.subscribers[Endpoint.calibration.uuid]!;
    await subscription.cancel();
    await transport.dispose();
    expect(
      () => active(Uint8List(De1CalibrationCodec.packetLength)),
      returnsNormally,
    );
    expect(
      () => stale(Uint8List(De1CalibrationCodec.packetLength)),
      returnsNormally,
    );
  });

  test('retired firmware-map callbacks cannot enter a new session', () async {
    final ble = FakeBleTransport();
    final rawNotifications = <Endpoint>[];
    final transport = UnifiedDe1Transport(
      transport: ble,
      onNotification: (endpoint, _) => rawNotifications.add(endpoint),
    );
    addTearDown(transport.dispose);
    await transport.connect();
    final retired = ble.subscribers[Endpoint.fwMapRequest.uuid]!;
    await transport.disconnect();
    await transport.connect();
    final values = <ByteData>[];
    final subscription = transport.fwMapRequest.listen(values.add);
    addTearDown(subscription.cancel);

    retired(Uint8List.fromList([1, 2, 3]));
    await pumpEventQueue();
    expect(values, isEmpty);

    ble.emitNotification(Endpoint.fwMapRequest, [4, 5, 6]);
    await pumpEventQueue();
    expect(values, hasLength(1));
    expect(values.single.getUint8(0), 4);
    expect(rawNotifications, isEmpty);
  });

  test('firmware-map callbacks cannot write to disposed subjects', () async {
    final ble = FakeBleTransport();
    final transport = UnifiedDe1Transport(transport: ble);
    await transport.connect();
    final retired = ble.subscribers[Endpoint.fwMapRequest.uuid]!;
    await transport.disconnect();
    await transport.connect();
    final active = ble.subscribers[Endpoint.fwMapRequest.uuid]!;
    await transport.dispose();

    expect(() => retired(Uint8List(3)), returnsNormally);
    expect(() => active(Uint8List(3)), returnsNormally);
  });
}
