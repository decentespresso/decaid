import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/calibration_codec.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

Uint8List _packet({
  int writeKey = 0,
  int command = 0,
  De1CalibrationTarget target = De1CalibrationTarget.flow,
  double reported = 0,
  double measured = 0,
}) {
  final bytes = ByteData(De1CalibrationCodec.packetLength);
  bytes.setUint32(0, writeKey, Endian.big);
  bytes.setUint8(4, command);
  bytes.setUint8(5, target.wireValue);
  bytes.setUint32(6, (reported * 65536).round(), Endian.big);
  bytes.setInt32(10, (measured * 65536).round(), Endian.big);
  return bytes.buffer.asUint8List();
}

class _FailingCalibrationWriteTransport extends FakeBleTransport {
  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (characteristicUUID == Endpoint.calibration.uuid) {
      throw StateError('simulated calibration write failure');
    }
    return super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }
}

void main() {
  late FakeBleTransport transport;
  late UnifiedDe1 de1;

  setUp(() async {
    transport = FakeBleTransport();
    transport.queueOnConnectResponses();
    de1 = UnifiedDe1(
      transport: transport,
      calibrationTimeout: const Duration(milliseconds: 200),
    );
    await de1.onConnect();
    transport.writes.clear();
  });

  tearDown(() => de1.dispose());

  test('reads current calibration for a target', () async {
    final future = de1.readCalibration(De1CalibrationTarget.flow);
    await pumpEventQueue();

    final write = transport.writes.single;
    expect(write.characteristicUUID, Endpoint.calibration.uuid);
    expect(write.withResponse, isTrue);
    expect(
      write.data,
      De1CalibrationCodec.encodeRead(De1CalibrationTarget.flow, factory: false),
    );

    transport.emitNotification(
      Endpoint.calibration,
      _packet(reported: 1.0, measured: 1.0),
    );
    expect(
      await future,
      const De1Calibration(
        target: De1CalibrationTarget.flow,
        de1ReportedValue: 1.0,
        measuredValue: 1.0,
      ),
    );
  });

  test('reads factory calibration with CalCommand 3', () async {
    final future = de1.readCalibration(
      De1CalibrationTarget.pressure,
      source: De1CalibrationSource.factory,
    );
    await pumpEventQueue();

    final write = transport.writes.single;
    expect(
      write.data,
      De1CalibrationCodec.encodeRead(
        De1CalibrationTarget.pressure,
        factory: true,
      ),
    );

    transport.emitNotification(
      Endpoint.calibration,
      _packet(
        command: De1CalibrationCodec.readCommand,
        target: De1CalibrationTarget.pressure,
        measured: 1.0,
      ),
    );
    await pumpEventQueue();

    transport.emitNotification(
      Endpoint.calibration,
      _packet(
        command: De1CalibrationCodec.factoryReadCommand,
        target: De1CalibrationTarget.pressure,
        reported: 8.5,
        measured: 8.25,
      ),
    );
    expect(
      await future,
      const De1Calibration(
        target: De1CalibrationTarget.pressure,
        de1ReportedValue: 8.5,
        measuredValue: 8.25,
      ),
    );
  });

  test(
    'reads complete only on returned data, not on write acknowledgements',
    () async {
      var completed = false;
      final future = de1.readCalibration(De1CalibrationTarget.flow).then((
        value,
      ) {
        completed = true;
        return value;
      });
      await pumpEventQueue();

      transport.emitNotification(
        Endpoint.calibration,
        _packet(
          writeKey: 0xCAFEF00D,
          command: De1CalibrationCodec.readCommand,
          target: De1CalibrationTarget.flow,
        ),
      );
      await pumpEventQueue();
      expect(completed, isFalse);

      transport.emitNotification(
        Endpoint.calibration,
        _packet(
          command: De1CalibrationCodec.readCommand,
          target: De1CalibrationTarget.flow,
          measured: 1.25,
        ),
      );
      expect(
        await future,
        const De1Calibration(
          target: De1CalibrationTarget.flow,
          de1ReportedValue: 0,
          measuredValue: 1.25,
        ),
      );
    },
  );

  test('writes calibration and waits for the write acknowledgement', () async {
    const calibration = De1Calibration(
      target: De1CalibrationTarget.temperature,
      de1ReportedValue: 93.5,
      measuredValue: -0.5,
    );
    var completed = false;
    final future = de1.writeCalibration(calibration).then((_) {
      completed = true;
    });
    await pumpEventQueue();

    final write = transport.writes.single;
    expect(write.characteristicUUID, Endpoint.calibration.uuid);
    expect(write.data, De1CalibrationCodec.encodeWrite(calibration));

    transport.emitNotification(
      Endpoint.calibration,
      _packet(
        command: De1CalibrationCodec.writeCommand,
        target: De1CalibrationTarget.temperature,
      ),
    );
    await pumpEventQueue();
    expect(completed, isFalse);

    transport.emitNotification(
      Endpoint.calibration,
      _packet(
        writeKey: 0xCAFEF00D,
        command: De1CalibrationCodec.writeCommand,
        target: De1CalibrationTarget.temperature,
      ),
    );
    await future;
  });

  test('ignores frames for unrelated targets', () async {
    var completed = false;
    final future = de1.readCalibration(De1CalibrationTarget.flow).then((value) {
      completed = true;
      return value;
    });
    await pumpEventQueue();

    transport.emitNotification(
      Endpoint.calibration,
      _packet(target: De1CalibrationTarget.pressure),
    );
    await pumpEventQueue();
    expect(completed, isFalse);

    transport.emitNotification(
      Endpoint.calibration,
      _packet(target: De1CalibrationTarget.flow, measured: 1.25),
    );
    expect(
      await future,
      const De1Calibration(
        target: De1CalibrationTarget.flow,
        de1ReportedValue: 0,
        measuredValue: 1.25,
      ),
    );
  });

  test('transport write errors propagate immediately', () async {
    final failingTransport = _FailingCalibrationWriteTransport()
      ..queueOnConnectResponses();
    final failingDe1 = UnifiedDe1(
      transport: failingTransport,
      calibrationTimeout: const Duration(milliseconds: 200),
    );
    await failingDe1.onConnect();
    addTearDown(failingDe1.dispose);

    await expectLater(
      failingDe1.writeCalibration(
        const De1Calibration(
          target: De1CalibrationTarget.flow,
          de1ReportedValue: 1.0,
          measuredValue: 1.0,
        ),
      ),
      throwsStateError,
    );
  });

  test('missing responses fail with EndpointUnavailableException', () async {
    await expectLater(
      de1.readCalibration(De1CalibrationTarget.flow),
      throwsA(isA<EndpointUnavailableException>()),
    );
  });

  test('concurrent calibration operations are serialized', () async {
    final first = de1.readCalibration(De1CalibrationTarget.flow);
    final second = de1.readCalibration(De1CalibrationTarget.pressure);
    await pumpEventQueue();

    expect(transport.writes, hasLength(1));
    expect(
      transport.writes.single.data,
      De1CalibrationCodec.encodeRead(De1CalibrationTarget.flow, factory: false),
    );

    transport.emitNotification(
      Endpoint.calibration,
      _packet(target: De1CalibrationTarget.flow, measured: 1.0),
    );
    await pumpEventQueue();
    expect(transport.writes, hasLength(2));
    expect(
      transport.writes.last.data,
      De1CalibrationCodec.encodeRead(
        De1CalibrationTarget.pressure,
        factory: false,
      ),
    );

    transport.emitNotification(
      Endpoint.calibration,
      _packet(target: De1CalibrationTarget.pressure, measured: 9.0),
    );
    expect((await first).target, De1CalibrationTarget.flow);
    expect((await second).target, De1CalibrationTarget.pressure);
  });

  test('flow estimation MMR API stays untouched by calibration', () async {
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 1234);
    expect(await de1.getFlowEstimation(), closeTo(1.234, 1e-9));
    await de1.setFlowEstimation(1.5);

    expect(
      transport.writes.where(
        (w) => w.characteristicUUID == Endpoint.calibration.uuid,
      ),
      isEmpty,
    );
    final mmrWrites = transport.writes
        .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
        .toList();
    expect(mmrWrites, hasLength(1));
    final address = ByteData(4)
      ..setInt32(0, MMRItem.calFlowEst.address, Endian.big);
    expect(mmrWrites.single.data[1], address.getUint8(1));
    expect(mmrWrites.single.data[2], address.getUint8(2));
    expect(mmrWrites.single.data[3], address.getUint8(3));
    expect(de1.cachedFlowEstimation, closeTo(1.5, 1e-9));
  });
}
