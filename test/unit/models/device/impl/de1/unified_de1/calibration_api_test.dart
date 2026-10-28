import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/calibration_codec.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
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

Uint8List _mmrResponse(int rawValue) {
  final resp = Uint8List(20);
  final view = ByteData.sublistView(resp);
  view.setUint8(0, 0);
  view.setUint8(1, (MMRItem.calFlowEst.address >> 16) & 0xff);
  view.setUint8(2, (MMRItem.calFlowEst.address >> 8) & 0xff);
  view.setUint8(3, MMRItem.calFlowEst.address & 0xff);
  view.setInt32(4, rawValue, Endian.little);
  return resp;
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

class _SwallowMmrReadTransport extends FakeBleTransport {
  bool swallowReads = false;
  int swallowedReads = 0;

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (swallowReads && characteristicUUID == Endpoint.readFromMMR.uuid) {
      swallowedReads++;
      return;
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

class _GatedCalibrationWriteTransport extends FakeBleTransport {
  final writeEntered = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (characteristicUUID == Endpoint.calibration.uuid) {
      if (!writeEntered.isCompleted) writeEntered.complete();
      await releaseWrite.future;
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

  test(
    'writes calibration and completes on the transport write acknowledgement',
    () async {
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
      expect(write.withResponse, isTrue);
      expect(write.data, De1CalibrationCodec.encodeWrite(calibration));

      // Mirrors de1app: the write completes on the BLE write event; no A012
      // notification is required or awaited.
      await future;
      expect(completed, isTrue);
    },
  );

  // The typed reset below is covered as an available but unwired primitive:
  // the generic machine-settings reset never sends an A012 packet.
  test(
    'sends a typed calibration reset request with write acknowledgement',
    () async {
      await de1.resetCalibration(De1CalibrationTarget.flow);

      final calibrationWrites = transport.writes
          .where(
            (write) => write.characteristicUUID == Endpoint.calibration.uuid,
          )
          .toList();
      expect(calibrationWrites, hasLength(1));
      expect(calibrationWrites.single.data, [
        0xCA, 0xFE, 0xF0, 0x0D, 0x02, 0x00, //
        0, 0, 0, 0, 0, 0, 0, 0,
      ]);
      expect(
        transport.writes.where(
          (write) => write.characteristicUUID == Endpoint.readFromMMR.uuid,
        ),
        isEmpty,
      );
      expect(de1.cachedFlowEstimation, 1.0);
    },
  );

  test(
    'typed calibration reset waits for the transport write acknowledgement',
    () async {
      final gatedTransport = _GatedCalibrationWriteTransport()
        ..queueOnConnectResponses();
      final gatedDe1 = UnifiedDe1(transport: gatedTransport);
      addTearDown(() async {
        if (!gatedTransport.releaseWrite.isCompleted) {
          gatedTransport.releaseWrite.complete();
        }
        await gatedDe1.dispose();
      });
      await gatedDe1.onConnect();
      gatedTransport.writes.clear();

      var completed = false;
      final resetFuture = gatedDe1
          .resetCalibration(De1CalibrationTarget.flow)
          .then((_) {
            completed = true;
          });
      await gatedTransport.writeEntered.future;
      await pumpEventQueue();
      expect(completed, isFalse);

      try {
        gatedTransport.releaseWrite.complete();
        await resetFuture;
        expect(completed, isTrue);
        expect(
          gatedTransport.writes.where(
            (write) => write.characteristicUUID == Endpoint.calibration.uuid,
          ),
          hasLength(1),
        );
      } finally {
        if (!gatedTransport.releaseWrite.isCompleted) {
          gatedTransport.releaseWrite.complete();
        }
      }
    },
  );

  test(
    'setFlowEstimation caches the effective clamped register value',
    () async {
      transport.queueMmrResponseIntSequence(MMRItem.calFlowEst, [2000, 2000]);

      await de1.setFlowEstimation(3.0);

      final mmrWrite = transport.writes.singleWhere(
        (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
      );
      expect(mmrWrite.data.sublist(0, 4), [0x04, 0x80, 0x38, 0x3C]);
      expect(
        ByteData.sublistView(mmrWrite.data).getUint32(4, Endian.little),
        2000,
      );
      expect(de1.cachedFlowEstimation, 2.0);
      expect(await de1.getFlowEstimation(), 2.0);
    },
  );

  test(
    'setFlowEstimation retains its previous cache when readback fails',
    () async {
      expect(de1.cachedFlowEstimation, 1.0);
      transport.dropNextMmrResponses = 1;

      await de1.setFlowEstimation(1.5);

      expect(de1.cachedFlowEstimation, 1.0);
    },
  );

  test(
    'flow refresh is retry-free: a dropped read keeps the cache and leaves the queued reply',
    () async {
      expect(de1.cachedFlowEstimation, 1.0);
      transport.dropNextMmrResponses = 1;
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 1250);

      await de1.setFlowEstimation(1.5);

      expect(de1.cachedFlowEstimation, 1.0);
      expect(await de1.getFlowEstimation(), closeTo(1.25, 1e-9));
      expect(de1.cachedFlowEstimation, closeTo(1.25, 1e-9));
    },
  );

  test('normal flow reads still retry a dropped response', () async {
    transport.dropNextMmrResponses = 1;
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 1300);

    expect(await de1.getFlowEstimation(), closeTo(1.3, 1e-9));
    expect(de1.cachedFlowEstimation, closeTo(1.3, 1e-9));
  });

  test(
    'overlapping flow writes complete in order with the latest value cached',
    () async {
      transport.queueMmrResponseIntSequence(MMRItem.calFlowEst, [1500, 1250]);

      final first = de1.setFlowEstimation(1.5);
      final second = de1.setFlowEstimation(1.25);
      await Future.wait([first, second]);

      final mmrWrites = transport.writes
          .where((w) => w.characteristicUUID == Endpoint.writeToMMR.uuid)
          .map((w) => ByteData.sublistView(w.data).getUint32(4, Endian.little))
          .toList();
      expect(mmrWrites, [1500, 1250]);
      expect(de1.cachedFlowEstimation, closeTo(1.25, 1e-9));

      transport.emitNotification(Endpoint.readFromMMR, _mmrResponse(1500));
      await pumpEventQueue();
      expect(de1.cachedFlowEstimation, closeTo(1.25, 1e-9));
    },
  );

  test('a superseded refresh cannot publish before the newer write', () async {
    final swallowed = _SwallowMmrReadTransport()..queueOnConnectResponses();
    final de1 = UnifiedDe1(transport: swallowed);
    addTearDown(de1.dispose);
    await de1.onConnect();
    swallowed.writes.clear();
    expect(de1.cachedFlowEstimation, 1.0);

    swallowed.swallowReads = true;
    final first = de1.setFlowEstimation(1.5);
    await pumpEventQueue();
    expect(swallowed.swallowedReads, 1);
    final second = de1.setFlowEstimation(1.25);

    // The first refresh resolves while superseded; it must not publish.
    swallowed.emitNotification(Endpoint.readFromMMR, _mmrResponse(1500));
    await first;
    expect(de1.cachedFlowEstimation, 1.0);

    swallowed.swallowReads = false;
    swallowed.queueMmrResponseInt(MMRItem.calFlowEst, 1250);
    await second;
    expect(de1.cachedFlowEstimation, closeTo(1.25, 1e-9));
  });

  test('a stale calibration read cannot publish after a newer write', () async {
    final swallowed = _SwallowMmrReadTransport()..queueOnConnectResponses();
    final held = UnifiedDe1(transport: swallowed);
    addTearDown(held.dispose);
    await held.onConnect();
    swallowed.writes.clear();
    expect(held.cachedFlowEstimation, 1.0);

    // Neither refresh read gets a reply, so both writes complete with the
    // last confirmed cache once the source-bounded reads give up.
    swallowed.swallowReads = true;
    await held.setFlowEstimation(1.5);
    await held.setFlowEstimation(1.25);
    expect(swallowed.swallowedReads, 2);
    expect(held.cachedFlowEstimation, 1.0);

    // Late replies to the dead reads must not overwrite the cache.
    swallowed.emitNotification(Endpoint.readFromMMR, _mmrResponse(1500));
    await pumpEventQueue();
    expect(held.cachedFlowEstimation, 1.0);

    swallowed.swallowReads = false;
    swallowed.queueMmrResponseInt(MMRItem.calFlowEst, 1500);
    expect(await held.getFlowEstimation(), closeTo(1.5, 1e-9));
  });

  test('a read superseded by a write does not overwrite the cache', () async {
    final swallowed = _SwallowMmrReadTransport()..queueOnConnectResponses();
    final de1 = UnifiedDe1(transport: swallowed);
    addTearDown(de1.dispose);
    await de1.onConnect();
    swallowed.writes.clear();
    expect(de1.cachedFlowEstimation, 1.0);

    swallowed.swallowReads = true;
    final pendingRead = de1.getFlowEstimation();
    await pumpEventQueue();
    await de1.setFlowEstimation(1.5);
    swallowed.emitNotification(Endpoint.readFromMMR, _mmrResponse(1500));
    expect(await pendingRead, closeTo(1.5, 1e-9));
    expect(de1.cachedFlowEstimation, 1.0);
  });

  test(
    'real and simulated writes reject multiplicative encoded zero',
    () async {
      final mock = MockDe1();
      for (final calibration in const [
        De1Calibration(
          target: De1CalibrationTarget.flow,
          de1ReportedValue: 0,
          measuredValue: 1,
        ),
        De1Calibration(
          target: De1CalibrationTarget.pressure,
          de1ReportedValue: 0.000001,
          measuredValue: 1,
        ),
      ]) {
        await expectLater(
          de1.writeCalibration(calibration),
          throwsArgumentError,
        );
        await expectLater(
          mock.writeCalibration(calibration),
          throwsArgumentError,
        );
      }
    },
  );

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
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 1500);
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
