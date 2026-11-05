import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../../../../../helpers/barrier_ble_transport.dart';
import '../../../../../../helpers/fake_ble_transport.dart';

void main() {
  late FakeBleTransport transport;
  late UnifiedDe1 de1;

  setUp(() async {
    transport = FakeBleTransport();
    addTearDown(transport.dispose);
    transport.queueOnConnectResponses(v13Model: 3, calFlowEst: 0);
    de1 = UnifiedDe1(
      transport: transport,
      firmwareEraseTimeout: const Duration(milliseconds: 100),
      firmwareVerificationTimeout: const Duration(milliseconds: 100),
    );
    await de1.onConnect();
  });

  test('completes only after successful verification response', () async {
    transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    var completed = false;
    final update = de1
        .updateFirmware(Uint8List(16), onProgress: (_) {})
        .whenComplete(() => completed = true);

    await _waitForState(de1, FirmwareUpdateState.verifying);
    expect(completed, isFalse);

    transport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    await update;
    expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
  });

  test('verification failure does not complete successfully', () async {
    transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    transport.queueFirmwareMapResponse([0, 0, 0, 1, 0, 0, 1]);

    await expectLater(
      de1.updateFirmware(Uint8List(16), onProgress: (_) {}),
      throwsA(isA<StateError>()),
    );
    expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
  });

  test('erase timeout prevents upload', () async {
    final writesBeforeUpdate = transport.writes.length;
    await expectLater(
      de1.updateFirmware(Uint8List(16), onProgress: (_) {}),
      throwsA(isA<TimeoutException>()),
    );
    expect(
      transport.writes
          .skip(writesBeforeUpdate)
          .where(
            (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
          ),
      isEmpty,
    );
  });

  test('stale successful response cannot complete erase', () async {
    transport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    final writesBeforeUpdate = transport.writes.length;

    await expectLater(
      de1.updateFirmware(Uint8List(16), onProgress: (_) {}),
      throwsA(isA<TimeoutException>()),
    );

    expect(
      transport.writes
          .skip(writesBeforeUpdate)
          .where(
            (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
          ),
      isEmpty,
    );
  });

  test('erase response must follow firmware-map dispatch', () async {
    final preflightTransport = _PreflightBarrierBleTransport();
    addTearDown(preflightTransport.dispose);
    preflightTransport.queueOnConnectResponses(v13Model: 3, calFlowEst: 0);
    final preflightBarrier = Completer<void>();
    final blockedDe1 = _PreludePreflightBlockingDe1(
      transport: preflightTransport,
      preflightBarrier: preflightBarrier,
      firmwareEraseTimeout: const Duration(milliseconds: 100),
      firmwareVerificationTimeout: const Duration(milliseconds: 100),
    );
    await blockedDe1.onConnect();
    preflightTransport.writes.clear();
    final uploadBarrier = Completer<void>();
    preflightTransport.pauseNextWrite(Endpoint.writeToMMR.uuid, uploadBarrier);
    final eraseWrite = preflightTransport.nextWrite(Endpoint.fwMapRequest.uuid);
    final update = blockedDe1.updateFirmware(Uint8List(16), onProgress: (_) {});

    await preflightTransport.waitForConnectionPreflight();
    preflightTransport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    preflightBarrier.complete();
    await eraseWrite;

    expect(blockedDe1.firmwareUpdateState, FirmwareUpdateState.erasing);
    expect(
      preflightTransport.writes
          .where(
            (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
          )
          .isEmpty,
      isTrue,
    );

    preflightTransport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    await _waitForState(blockedDe1, FirmwareUpdateState.uploading);
    await blockedDe1.cancelFirmwareUpload();
    uploadBarrier.complete();
    await expectLater(update, throwsA(isA<FirmwareUpdateCancelledException>()));
  });

  test('late erase response does not complete verification', () async {
    transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    final update = de1.updateFirmware(Uint8List(16), onProgress: (_) {});

    await _waitForState(de1, FirmwareUpdateState.verifying);
    transport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);

    await Future<void>.delayed(Duration.zero);
    expect(de1.firmwareUpdateState, FirmwareUpdateState.verifying);
    transport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    await update;
    expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
  });

  test('verification response must follow the verification request', () async {
    final barrierTransport = BarrierBleTransport();
    addTearDown(barrierTransport.dispose);
    barrierTransport.queueOnConnectResponses(v13Model: 3, calFlowEst: 0);
    final blockedDe1 = UnifiedDe1(
      transport: barrierTransport,
      firmwareEraseTimeout: const Duration(milliseconds: 100),
      firmwareVerificationTimeout: const Duration(milliseconds: 100),
    );
    await blockedDe1.onConnect();
    barrierTransport.writes.clear();
    final uploadBarrier = Completer<void>();
    barrierTransport.pauseNextWrite(Endpoint.writeToMMR.uuid, uploadBarrier);
    barrierTransport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    final uploadWrite = barrierTransport.nextWrite(Endpoint.writeToMMR.uuid);
    final update = blockedDe1.updateFirmware(Uint8List(16), onProgress: (_) {});

    await uploadWrite;
    barrierTransport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    expect(blockedDe1.firmwareUpdateState, FirmwareUpdateState.uploading);

    uploadBarrier.complete();
    await _waitForState(blockedDe1, FirmwareUpdateState.verifying);
    barrierTransport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    await update;
    expect(blockedDe1.firmwareUpdateState, FirmwareUpdateState.idle);
  });

  test('verification response must follow firmware-map dispatch', () async {
    final preflightTransport = _PreflightBarrierBleTransport();
    addTearDown(preflightTransport.dispose);
    preflightTransport.queueOnConnectResponses(v13Model: 3, calFlowEst: 0);
    final blockedDe1 = UnifiedDe1(
      transport: preflightTransport,
      firmwareEraseTimeout: const Duration(milliseconds: 100),
      firmwareVerificationTimeout: const Duration(milliseconds: 100),
    );
    await blockedDe1.onConnect();
    preflightTransport.writes.clear();
    final uploadBarrier = Completer<void>();
    preflightTransport.pauseNextWrite(Endpoint.writeToMMR.uuid, uploadBarrier);
    preflightTransport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    final uploadWrite = preflightTransport.nextWrite(Endpoint.writeToMMR.uuid);
    final verificationWrite = preflightTransport.nextWrite(
      Endpoint.fwMapRequest.uuid,
    );
    final update = blockedDe1.updateFirmware(Uint8List(16), onProgress: (_) {});

    await uploadWrite;
    preflightTransport.pauseNextConnectionPreflight(Completer<void>());
    final preflightStarted = preflightTransport.waitForConnectionPreflight();
    uploadBarrier.complete();
    await preflightStarted;
    preflightTransport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    preflightTransport.releaseConnectionPreflight();
    await verificationWrite;

    expect(blockedDe1.firmwareUpdateState, FirmwareUpdateState.verifying);
    await Future<void>.delayed(Duration.zero);
    preflightTransport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    await update;
  });

  test('cancellation while verifying is typed and returns to idle', () async {
    transport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    final update = de1.updateFirmware(Uint8List(16), onProgress: (_) {});
    final cancellation = expectLater(
      update,
      throwsA(isA<FirmwareUpdateCancelledException>()),
    );
    await _waitForState(de1, FirmwareUpdateState.verifying);

    await de1.cancelFirmwareUpload();
    await cancellation;
    expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
  });

  test('disconnect cancels an active update', () async {
    final update = de1.updateFirmware(Uint8List(16), onProgress: (_) {});
    final cancellation = expectLater(
      update,
      throwsA(isA<FirmwareUpdateCancelledException>()),
    );
    await de1.disconnect();

    await cancellation;
    expect(de1.firmwareUpdateState, FirmwareUpdateState.idle);
  });

  test('diagnostic trace compares success with injected requested-state '
      'sleep-write timeout', () async {
    final previousRootLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final logs = <LogRecord>[];
    final logSubscription = Logger.root.onRecord.listen(logs.add);
    addTearDown(() async {
      await logSubscription.cancel();
      Logger.root.level = previousRootLevel;
    });

    final successTransport = BarrierBleTransport();
    addTearDown(successTransport.dispose);
    successTransport.queueOnConnectResponses(v13Model: 3, calFlowEst: 0);
    final successDe1 = UnifiedDe1(
      transport: successTransport,
      firmwareEraseTimeout: const Duration(seconds: 1),
      firmwareVerificationTimeout: const Duration(seconds: 1),
    );
    await successDe1.onConnect();
    final successConnectTrace = List<String>.of(successTransport.trace);
    successTransport.trace.clear();
    successTransport.queueMmrResponseInt(MMRItem.calFlowEst, 1000);
    expect(await successDe1.getFlowEstimation(), 1.0);
    successTransport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    final uploadBarrier = Completer<void>();
    successTransport.pauseNextWrite(Endpoint.writeToMMR.uuid, uploadBarrier);
    final success = successDe1.updateFirmware(
      Uint8List(16),
      onProgress: (_) {},
    );
    await _waitForState(successDe1, FirmwareUpdateState.uploading);
    uploadBarrier.complete();
    await Future<void>.delayed(Duration.zero);
    successTransport.emitFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    await success;
    debugPrint(
      'diagnostic success connect trace:\\n'
      '${successConnectTrace.join('\\n')}',
    );
    debugPrint(
      'diagnostic success trace:\\n${successTransport.trace.join('\\n')}',
    );
    final imageWriteLogs = logs
        .where(
          (record) =>
              record.loggerName.startsWith('UnifiedDe1Transport-') &&
              record.level == Level.FINE,
        )
        .toList();
    expect(
      imageWriteLogs.any(
        (record) => record.message.contains('about to write to writeToMMR'),
      ),
      isTrue,
    );
    expect(
      imageWriteLogs.any(
        (record) => record.message.contains(
          '10 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00',
        ),
      ),
      isFalse,
    );

    final failureTransport = FakeBleTransport();
    addTearDown(failureTransport.dispose);
    failureTransport.queueOnConnectResponses(v13Model: 3, calFlowEst: 0);
    failureTransport.requestedStateSleepWriteTimeout = const Duration(
      seconds: 2,
    );
    final failureDe1 = UnifiedDe1(
      transport: failureTransport,
      firmwareEraseTimeout: const Duration(seconds: 1),
      firmwareVerificationTimeout: const Duration(seconds: 1),
    );
    await failureDe1.onConnect();
    final failureConnectTrace = List<String>.of(failureTransport.trace);
    failureTransport.trace.clear();
    failureTransport.queueMmrResponseInt(MMRItem.calFlowEst, 1000);
    expect(await failureDe1.getFlowEstimation(), 1.0);
    failureTransport.writes.clear();

    Object? failure;
    StackTrace? failureStack;
    try {
      await failureDe1.updateFirmware(Uint8List(16), onProgress: (_) {});
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    debugPrint(
      'diagnostic failure connect trace:\\n'
      '${failureConnectTrace.join('\\n')}',
    );
    debugPrint(
      'diagnostic failure trace:\\n${failureTransport.trace.join('\\n')}',
    );
    debugPrint('diagnostic failure error: $failure\\n$failureStack');
    expect(failure, isA<FirmwareUpdateStageException>());
    final failureStage = failure as FirmwareUpdateStageException;
    expect(failureStage.stage, 'sleep');
    expect(failureStage.cause, isA<TimeoutException>());
    expect(
      failureStage.stackTrace.toString(),
      contains('FakeBleTransport.write'),
    );
    expect(failureStage.toString(), failureStage.cause.toString());
    final stageFailureLog = logs.singleWhere(
      (record) => record.message.contains('firmware stage=sleep failed'),
    );
    expect(stageFailureLog.message, contains('stage=sleep'));
    expect(stageFailureLog.message, contains('cause=TimeoutException'));
    expect(stageFailureLog.error, isA<TimeoutException>());
    expect(stageFailureLog.stackTrace, isNotNull);
    expect(failureDe1.firmwareUpdateState, FirmwareUpdateState.idle);
    expect(
      failureTransport.trace.any(
        (event) => event.contains('write endpoint=requestedState'),
      ),
      isTrue,
    );
    expect(
      failureTransport.writes.any(
        (write) => write.characteristicUUID == Endpoint.fwMapRequest.uuid,
      ),
      isFalse,
    );
    expect(
      failureTransport.writes.any(
        (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
      ),
      isFalse,
    );

    failureTransport.writes.clear();
    failureTransport.requestedStateSleepWriteTimeout = null;
    failureTransport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xff]);
    failureTransport.queueFirmwareMapResponse([0, 0, 0, 1, 0xff, 0xff, 0xfd]);
    final subsequentImage = Uint8List.fromList(
      List<int>.generate(16, (index) => index + 1),
    );
    await failureDe1.updateFirmware(subsequentImage, onProgress: (_) {});
    debugPrint(
      'diagnostic subsequent trace:\\n${failureTransport.trace.join('\\n')}',
    );
    expect(failureDe1.firmwareUpdateState, FirmwareUpdateState.idle);
    expect(failureTransport.connectCalls, 1);
    final subsequentMapWrites = failureTransport.writes
        .where(
          (write) => write.characteristicUUID == Endpoint.fwMapRequest.uuid,
        )
        .toList();
    expect(subsequentMapWrites, hasLength(2));
    expect(
      subsequentMapWrites.where((write) => write.data[2] == 1),
      hasLength(1),
    );
    final subsequentImageWrites = failureTransport.writes
        .where((write) => write.characteristicUUID == Endpoint.writeToMMR.uuid)
        .toList();
    expect(subsequentImageWrites, hasLength(1));
    expect(
      subsequentImageWrites.single.data,
      orderedEquals([16, 0, 0, 0, ...subsequentImage]),
    );
  });
}

Future<void> _waitForState(UnifiedDe1 de1, FirmwareUpdateState state) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (de1.firmwareUpdateState != state) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('State did not become ${state.name}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _PreludePreflightBlockingDe1 extends UnifiedDe1 {
  _PreludePreflightBlockingDe1({
    required _PreflightBarrierBleTransport transport,
    required this.preflightBarrier,
    required super.firmwareEraseTimeout,
    required super.firmwareVerificationTimeout,
  }) : _testTransport = transport,
       super(transport: transport);

  final _PreflightBarrierBleTransport _testTransport;
  final Completer<void> preflightBarrier;

  @override
  Future<void> beforeFirmwareUpload() async {
    _testTransport.pauseNextConnectionPreflight(preflightBarrier);
  }
}

final class _PreflightBarrierBleTransport extends BarrierBleTransport {
  Completer<void>? _connectionPreflightBarrier;
  Completer<void>? _connectionPreflightStarted;

  Future<void> waitForConnectionPreflight() async {
    while (_connectionPreflightStarted == null) {
      await Future<void>.delayed(Duration.zero);
    }
    await _connectionPreflightStarted!.future;
  }

  void pauseNextConnectionPreflight(Completer<void> barrier) {
    _connectionPreflightBarrier = barrier;
    _connectionPreflightStarted = Completer<void>();
  }

  void releaseConnectionPreflight() {
    _connectionPreflightBarrier!.complete();
  }

  @override
  Stream<device.ConnectionState> get connectionState async* {
    final barrier = _connectionPreflightBarrier;
    final started = _connectionPreflightStarted;
    if (barrier != null && started != null) {
      started.complete();
      await barrier.future;
      _connectionPreflightBarrier = null;
      _connectionPreflightStarted = null;
    }
    yield* super.connectionState;
  }
}
