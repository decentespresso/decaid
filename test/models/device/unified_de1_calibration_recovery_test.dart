import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';

import '../../helpers/recovering_firmware_transport.dart';

const _watchdog = Duration(seconds: 5);

typedef _Session = ({UnifiedDe1 de1, RecoveringFirmwareTransport transport});

Future<T> _within<T>(Future<T> future, String label) => future.timeout(
  _watchdog,
  onTimeout: () => throw StateError('$label did not complete'),
);

Future<void> _pumpUntil(bool Function() condition, String label) async {
  for (var turn = 0; turn < 500; turn++) {
    if (condition()) return;
    await pumpEventQueue(times: 1);
  }
  fail('condition not met: $label');
}

UnifiedDe1 _build(RecoveringFirmwareTransport transport) => UnifiedDe1(
  transport: transport,
  calibrationTimeout: const Duration(milliseconds: 200),
);

Future<_Session> _connect({int rawCalFlowEst = 1000}) async {
  final transport = RecoveringFirmwareTransport()
    ..machineRawCalFlowEst = rawCalFlowEst;
  final de1 = _build(transport);
  addTearDown(de1.dispose);
  await _within(de1.onConnect(), 'connect');
  transport.writes.clear();
  return (de1: de1, transport: transport);
}

final class _RecordingDe1 extends UnifiedDe1 {
  _RecordingDe1({required super.transport, required super.calibrationTimeout});

  int getFlowEstimationCalls = 0;
  Completer<void>? _nextEntry;
  int _barrierSkip = 0;

  Future<void> armGetFlowEstimationBarrier({int skip = 0}) {
    final completer = Completer<void>();
    _nextEntry = completer;
    _barrierSkip = skip;
    return completer.future;
  }

  @override
  Future<double> getFlowEstimation() {
    getFlowEstimationCalls++;
    final future = super.getFlowEstimation();
    final pending = _nextEntry;
    if (pending != null) {
      if (_barrierSkip > 0) {
        _barrierSkip--;
      } else {
        _nextEntry = null;
        if (!pending.isCompleted) pending.complete();
      }
    }
    return future;
  }
}

void main() {
  test(
    'an unrelated MMR write recovers and refreshes the session multiplier',
    () async {
      for (final raw in [800, 1250]) {
        final session = await _connect();
        expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));
        final readsAfterConnect = session.transport.calFlowEstReads;

        session.transport.machineRawCalFlowEst = raw;
        session.transport.timeoutNextMmrWrite();

        await _within(
          session.de1.setFanThreshhold(20),
          'unrelated MMR write recovery',
        );

        expect(session.transport.reconnectAttempts, 1);
        expect(
          session.transport.writes.where(
            (write) => write.characteristicUUID == Endpoint.writeToMMR.uuid,
          ),
          hasLength(2),
        );

        await _pumpUntil(
          () => session.de1.cachedFlowEstimation != null,
          'the multiplier to be refreshed after recovery',
        );

        expect(session.de1.cachedFlowEstimation, closeTo(raw / 1000, 1e-9));
        expect(
          session.transport.calFlowEstReads,
          greaterThan(readsAfterConnect),
          reason: 'the refreshed value comes from a fresh machine read',
        );
        expect(
          session.transport.calFlowEstWrites,
          isEmpty,
          reason: 'a recovered session is read-only for calFlowEst',
        );
      }
    },
  );

  test(
    'an unrelated non-MMR write recovers and refreshes the session multiplier',
    () async {
      final session = await _connect();
      expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));
      final readsAfterConnect = session.transport.calFlowEstReads;

      session.transport.machineRawCalFlowEst = 800;
      session.transport.timeoutNextRequestedStateWrite = true;

      await _within(
        session.de1.requestState(MachineState.sleeping),
        'unrelated non-MMR write recovery',
      );

      expect(session.transport.reconnectAttempts, 1);
      await _pumpUntil(
        () => session.de1.cachedFlowEstimation != null,
        'the multiplier to be refreshed after non-MMR recovery',
      );

      expect(session.de1.cachedFlowEstimation, closeTo(0.8, 1e-9));
      expect(session.transport.calFlowEstReads, greaterThan(readsAfterConnect));
      expect(
        session.transport.calFlowEstWrites,
        isEmpty,
        reason: 'a recovered session never writes calFlowEst',
      );
    },
  );

  test('a failed refresh after recovery leaves the multiplier unknown without '
      'blocking the session', () async {
    final session = await _connect();
    final readsAfterConnect = session.transport.calFlowEstReads;

    session.transport.failCalFlowEstReads = true;
    session.transport.timeoutNextMmrWrite();
    await _within(
      session.de1.setFanThreshhold(20),
      'unrelated MMR write recovery',
    );

    await _pumpUntil(
      () => session.transport.calFlowEstReads > readsAfterConnect,
      'the calibration read attempted after recovery',
    );
    await pumpEventQueue();

    expect(session.de1.cachedFlowEstimation, isNull);
    expect(session.transport.calFlowEstWrites, isEmpty);

    session.transport.firmwareWords[MMRItem.flushTimeout.address] = 50;
    expect(
      await _within(
        session.de1.getFlushTimeout(),
        'unrelated read while the multiplier is unknown',
      ),
      closeTo(5.0, 1e-9),
    );
    expect(session.de1.cachedFlowEstimation, isNull);

    session.transport.failCalFlowEstReads = false;
    session.transport.machineRawCalFlowEst = 800;
    expect(
      await _within(session.de1.getFlowEstimation(), 'read after recovery'),
      closeTo(0.8, 1e-9),
    );
    expect(session.de1.cachedFlowEstimation, closeTo(0.8, 1e-9));
    expect(session.transport.calFlowEstWrites, isEmpty);
  });

  test(
    'recovery inside an explicit calibration write leaves the effective value '
    'in the session cache and in a following read',
    () async {
      final session = await _connect();
      session.transport.timeoutNextMmrWrite();

      await _within(
        session.de1.setFlowEstimation(1.5),
        'explicit calibration write',
      );

      expect(session.transport.reconnectAttempts, 1);
      expect(session.transport.calFlowEstWrites, [1500, 1500]);
      expect(
        session.de1.cachedFlowEstimation,
        closeTo(1.5, 1e-9),
        reason: 'the recovered write must cache the effective value',
      );

      expect(
        await _within(
          session.de1.getFlowEstimation(),
          'read after the recovered write',
        ),
        closeTo(1.5, 1e-9),
      );
      expect(session.de1.cachedFlowEstimation, closeTo(1.5, 1e-9));
      expect(session.transport.calFlowEstWrites, [1500, 1500]);
    },
  );

  test('a recovered calibration write leaves the multiplier unknown when the '
      'follow-up observation fails', () async {
    final session = await _connect();
    session.transport.failCalFlowEstReads = true;
    session.transport.timeoutNextMmrWrite();

    await _within(
      session.de1.setFlowEstimation(1.5),
      'recovered calibration write',
    );
    await pumpEventQueue(times: 20);

    expect(session.transport.reconnectAttempts, 1);
    expect(session.transport.calFlowEstWrites, [1500, 1500]);
    expect(
      session.de1.cachedFlowEstimation,
      isNull,
      reason: 'a failed observation cannot be reported as a read success',
    );

    await expectLater(
      _within(session.de1.getFlowEstimation(), 'read while unknown'),
      throwsA(isA<StateError>()),
    );
    expect(session.de1.cachedFlowEstimation, isNull);

    session.transport.failCalFlowEstReads = false;
    session.transport.machineRawCalFlowEst = 800;
    expect(
      await _within(
        session.de1.getFlowEstimation(),
        'read after a successful observation',
      ),
      closeTo(0.8, 1e-9),
    );
    expect(session.de1.cachedFlowEstimation, closeTo(0.8, 1e-9));
    expect(session.transport.calFlowEstWrites, [1500, 1500]);
  });

  test('a refresh that itself times out stops reconnecting and leaves the '
      'multiplier unknown', () async {
    final session = await _connect();
    session.transport.alwaysTimeoutCalFlowEstReads = true;
    session.transport.reconnectBudget = 4;
    session.transport.timeoutNextMmrWrite();

    await _within(
      session.de1.setFanThreshhold(20),
      'unrelated MMR write recovery',
    );
    await pumpEventQueue(times: 400);

    expect(session.de1.cachedFlowEstimation, isNull);
    expect(session.transport.calFlowEstWrites, isEmpty);
    expect(
      session.transport.reconnectAttempts,
      lessThanOrEqualTo(3),
      reason:
          'a refresh that provokes its own BLE timeout must not '
          'reconnect without bound',
    );
  });

  test('an unsolicited transport disconnect during a calibration write cannot '
      'stamp the written value onto the next session', () async {
    final session = await _connect();
    expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));

    session.transport.holdNextMmrWrite = true;
    final write = session.de1.setFlowEstimation(1.5);
    await _within(
      session.transport.mmrWriteDispatched.future,
      'the calibration write to be dispatched',
    );

    session.transport.emitConnectionState(ConnectionState.disconnected);
    await _pumpUntil(
      () => session.de1.cachedFlowEstimation == null,
      'the unsolicited disconnect to fence the cached multiplier',
    );
    expect(session.transport.reconnectAttempts, 0);

    session.transport.releaseMmrWrite();
    await _within(write, 'the calibration write that outlived its session');
    await pumpEventQueue(times: 20);

    expect(
      session.de1.cachedFlowEstimation,
      isNull,
      reason:
          'a value acknowledged by the previous session cannot describe '
          'the session that replaced it',
    );
    expect(session.transport.calFlowEstWrites, [1500]);
  });

  test(
    'a refresh that lands after the session ended cannot repopulate the cache',
    () async {
      final session = await _connect();
      session.transport.holdCalFlowEstReads = true;
      session.transport.timeoutNextMmrWrite();

      await _within(
        session.de1.setFanThreshhold(20),
        'unrelated MMR write recovery',
      );
      await _within(
        session.transport.calFlowEstReadEntered.future,
        'the calibration read issued after recovery',
      );
      final readsBeforeRelease = session.transport.calFlowEstReads;

      await _within(session.de1.onDisconnect(), 'the session to end');
      expect(session.de1.cachedFlowEstimation, isNull);

      session.transport.machineRawCalFlowEst = 800;
      session.transport.releaseCalFlowEstRead();
      await _within(
        session.transport.heldCalFlowEstReadSettled.future,
        'the released calibration read',
      );
      await pumpEventQueue();

      expect(
        session.transport.heldCalFlowEstResponses,
        1,
        reason:
            'the released read answers with a real machine word instead of '
            'failing early',
      );
      expect(session.transport.heldCalFlowEstResponseWord, 800);
      expect(
        session.de1.cachedFlowEstimation,
        isNull,
        reason:
            'the response outlived its session, so the session fence '
            'rejects it',
      );
      expect(
        session.transport.calFlowEstReads,
        readsBeforeRelease,
        reason: 'an ended session does not start another calibration read',
      );
      expect(
        session.transport.reconnectAttempts,
        1,
        reason: 'a fenced refresh does not queue a background retry',
      );
      expect(session.transport.calFlowEstWrites, isEmpty);
    },
  );

  test(
    'a refresh that lands after dispose cannot repopulate the cache',
    () async {
      final transport = RecoveringFirmwareTransport()
        ..machineRawCalFlowEst = 1000;
      final de1 = _build(transport);
      await _within(de1.onConnect(), 'connect');

      transport.holdCalFlowEstReads = true;
      transport.failReleasedCalFlowEstReads = true;
      transport.timeoutNextMmrWrite();
      await _within(de1.setFanThreshhold(20), 'unrelated MMR write recovery');
      await _within(
        transport.calFlowEstReadEntered.future,
        'the calibration read issued after recovery',
      );
      final readsBeforeRelease = transport.calFlowEstReads;

      await _within(de1.dispose(), 'dispose');
      transport.machineRawCalFlowEst = 800;
      transport.releaseCalFlowEstRead();
      await _within(
        transport.heldCalFlowEstReadSettled.future,
        'the released calibration read',
      );
      await pumpEventQueue();

      expect(
        transport.heldCalFlowEstResponses,
        1,
        reason:
            'the disposed read still answers with a real machine word '
            'before the dead link is reported',
      );
      expect(transport.heldCalFlowEstResponseWord, 800);
      expect(de1.cachedFlowEstimation, isNull);
      expect(
        transport.calFlowEstReads,
        readsBeforeRelease,
        reason: 'a disposed session does not retry the calibration read',
      );
      expect(transport.calFlowEstWrites, isEmpty);
    },
  );

  test(
    'a refused reconnect leaves the multiplier unknown and writes nothing',
    () async {
      final session = await _connect();
      session.transport.refuseReconnect = true;
      session.transport.timeoutNextMmrWrite();

      await expectLater(
        _within(
          session.de1.setFanThreshhold(20),
          'unrelated MMR write recovery',
        ),
        throwsA(isA<BleTimeoutException>()),
      );

      expect(session.transport.reconnectAttempts, 1);
      expect(session.de1.cachedFlowEstimation, isNull);
      expect(session.transport.calFlowEstWrites, isEmpty);
    },
  );

  test('recovery triggered inside an MMR read does not deadlock the '
      'post-recovery refresh', () async {
    final session = await _connect();
    final readsAfterConnect = session.transport.calFlowEstReads;
    session.transport.firmwareWords[MMRItem.flushTimeout.address] = 50;
    session.transport.machineRawCalFlowEst = 1250;
    session.transport.timeoutNextMmrRead();

    expect(
      await _within(session.de1.getFlushTimeout(), 'MMR read recovery'),
      closeTo(5.0, 1e-9),
    );
    expect(session.transport.reconnectAttempts, 1);

    await _pumpUntil(
      () => session.de1.cachedFlowEstimation != null,
      'the refresh completed during a recovered MMR read',
    );
    expect(session.de1.cachedFlowEstimation, closeTo(1.25, 1e-9));
    expect(session.transport.calFlowEstReads, greaterThan(readsAfterConnect));
    expect(session.transport.calFlowEstWrites, isEmpty);
  });

  test(
    'a calibration write that outlives its session cannot start a calibration '
    'read in the session that replaced it',
    () async {
      final session = await _connect();
      expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));

      session.transport.holdNextMmrWrite = true;
      final write = session.de1.setFlowEstimation(1.5);
      await _within(
        session.transport.mmrWriteDispatched.future,
        'the calibration write to be dispatched',
      );

      session.transport.emitConnectionState(ConnectionState.disconnected);
      await _pumpUntil(
        () => session.de1.cachedFlowEstimation == null,
        'the unsolicited disconnect to fence the cached multiplier',
      );

      session.transport.holdCalFlowEstReads = true;
      session.transport.emitConnectionState(ConnectionState.connected);
      final reconnect = session.de1.onConnect();
      await pumpEventQueue();
      final readsBeforeRelease = session.transport.calFlowEstReads;

      session.transport.machineRawCalFlowEst = 800;
      session.transport.releaseMmrWrite();
      await _within(
        session.transport.calFlowEstReadEntered.future,
        'the calibration read of the replacing session',
      );
      session.transport.holdCalFlowEstReads = false;
      session.transport.releaseCalFlowEstRead();

      await _within(write, 'the calibration write that outlived its session');
      await _within(reconnect, 'the reconnect that replaced the session');
      await pumpEventQueue(times: 50);

      expect(
        session.transport.calFlowEstReads,
        readsBeforeRelease + 1,
        reason:
            'only the replacing session observes the multiplier; a write '
            'acknowledged by the ended session must not read it',
      );
      expect(session.de1.cachedFlowEstimation, closeTo(0.8, 1e-9));
      expect(session.transport.calFlowEstWrites, [1500]);
    },
  );

  test('a session that ends during a held reconnect cannot be repopulated by '
      'the post-recovery refresh', () async {
    final session = await _connect();
    expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));
    final readsAfterConnect = session.transport.calFlowEstReads;

    session.transport.machineRawCalFlowEst = 800;
    session.transport.holdNextConnect = true;
    session.transport.timeoutNextMmrWrite();
    final write = session.de1.setFanThreshhold(20);
    await _within(
      session.transport.connectEntered.future,
      'the reconnect to start',
    );

    await _within(
      session.de1.onDisconnect(),
      'the session to end during the reconnect',
    );
    session.transport.releaseConnect();

    await _within(write, 'the write that outlived its session');
    await pumpEventQueue(times: 50);

    expect(session.transport.reconnectAttempts, 1);
    expect(
      session.transport.calFlowEstReads,
      readsAfterConnect,
      reason:
          'a recovery that completes after the session ended must not read '
          'the multiplier for that session',
    );
    expect(session.de1.cachedFlowEstimation, isNull);
    expect(session.transport.calFlowEstWrites, isEmpty);
  });

  test('a queued post-recovery refresh cannot rebind to a session that ended '
      'while it was in flight', () async {
    final session = await _connect();
    expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));

    session.transport.holdCalFlowEstReads = true;
    session.transport.timeoutNextMmrWrite();
    await _within(
      session.de1.setFanThreshhold(20),
      'the unrelated MMR write recovery',
    );
    await _within(
      session.transport.calFlowEstReadEntered.future,
      'the post-recovery calibration read',
    );

    session.transport.holdNextConnect = true;
    session.transport.timeoutNextRequestedStateWrite = true;
    final unrelated = session.de1.requestState(MachineState.sleeping);
    await _within(
      session.transport.connectEntered.future,
      'the second reconnect to start',
    );

    await _within(
      session.de1.onDisconnect(),
      'the session to end during the second reconnect',
    );
    session.transport.holdCalFlowEstReads = false;
    session.transport.machineRawCalFlowEst = 800;
    session.transport.releaseConnect();
    await _within(unrelated, 'the write that outlived its session');
    final readsBeforeRelease = session.transport.calFlowEstReads;

    session.transport.releaseCalFlowEstRead();
    await pumpEventQueue(times: 50);

    expect(
      session.transport.calFlowEstReads,
      readsBeforeRelease,
      reason:
          'a queued refresh retry must not observe the ended session through '
          'a replacement epoch',
    );
    expect(session.de1.cachedFlowEstimation, isNull);
  });

  test('a recovery that lands while the replacing session reads the multiplier is '
      'not swallowed by the session that ended', () async {
    final transport = RecoveringFirmwareTransport()
      ..machineRawCalFlowEst = 1000;
    final de1 = _RecordingDe1(
      transport: transport,
      calibrationTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(de1.dispose);
    await _within(de1.onConnect(), 'connect');
    expect(de1.cachedFlowEstimation, closeTo(1.0, 1e-9));

    transport.holdCalFlowEstReads = true;
    transport.timeoutNextMmrWrite();
    await _within(de1.setFanThreshhold(20), 'unrelated MMR write recovery');
    await _within(
      transport.calFlowEstReadEntered.future,
      'the post-recovery calibration read',
    );
    expect(transport.reconnectAttempts, 1);
    final heldReads = transport.calFlowEstReads;

    await _within(de1.onDisconnect(), 'the session to end');
    expect(de1.cachedFlowEstimation, isNull);

    final replacementRead = de1.armGetFlowEstimationBarrier();
    final replacement = de1.onConnect();
    await _within(replacementRead, 'the replacement session calibration read');
    final callsAtBarrier = de1.getFlowEstimationCalls;
    final reconnectsAtBarrier = transport.reconnectAttempts;
    expect(
      transport.calFlowEstReads,
      heldReads,
      reason:
          'the replacement read waits on the MMR gate of the held read '
          'instead of being dispatched',
    );

    transport.timeoutNextRequestedStateWrite = true;
    await _within(
      de1.requestState(MachineState.sleeping),
      'the non-MMR timeout recovery',
    );
    expect(transport.reconnectAttempts, reconnectsAtBarrier + 1);
    expect(
      transport.calFlowEstReads,
      heldReads,
      reason: 'the read queued before the recovery is still held',
    );

    transport.machineRawCalFlowEst = 800;
    transport.holdCalFlowEstReads = false;
    transport.releaseCalFlowEstRead();

    await _within(replacement, 'the replacement session');
    await pumpEventQueue(times: 50);
    await _pumpUntil(
      () => de1.cachedFlowEstimation != null,
      'the refresh queued for the replacement session '
      '(cache=${de1.cachedFlowEstimation}, reads=${transport.calFlowEstReads}, '
      'reconnects=${transport.reconnectAttempts})',
    );

    expect(transport.heldCalFlowEstResponses, 1);
    expect(transport.heldCalFlowEstResponseWord, 800);
    expect(de1.cachedFlowEstimation, closeTo(0.8, 1e-9));
    expect(transport.calFlowEstWrites, isEmpty);
    expect(
      transport.calFlowEstReads,
      inInclusiveRange(heldReads + 1, heldReads + 2),
      reason:
          'at most the replacement read and one refresh read for the '
          'replacement session',
    );
    expect(
      de1.getFlowEstimationCalls,
      callsAtBarrier,
      reason:
          'the replacement session must observe the queued refresh instead '
          'of a further caller GET',
    );
  });

  test('an observation queued behind a held read before the session ends '
      'never reads the multiplier for that session', () async {
    final session = await _connect();
    expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));

    session.transport.holdCalFlowEstReads = true;
    final heldGet = session.de1.getFlowEstimation();
    await _within(
      session.transport.calFlowEstReadEntered.future,
      'the ordinary calibration read that owns the MMR gate',
    );
    final readsWhileHeld = session.transport.calFlowEstReads;

    session.transport.timeoutNextRequestedStateWrite = true;
    await _within(
      session.de1.requestState(MachineState.sleeping),
      'the non-MMR BLE timeout recovery',
    );

    expect(session.transport.reconnectAttempts, 1);
    expect(session.transport.heldCalFlowEstResponses, 0);
    expect(
      session.transport.calFlowEstReads,
      readsWhileHeld,
      reason: 'the automatic observation is queued behind the held gate',
    );

    await _within(session.de1.onDisconnect(), 'the session to end');

    session.transport.machineRawCalFlowEst = 800;
    session.transport.holdCalFlowEstReads = false;
    session.transport.releaseCalFlowEstRead();
    await _within(
      session.transport.heldCalFlowEstReadSettled.future,
      'the released ordinary read',
    );
    expect(
      await _within(heldGet, 'the ordinary read that outlived its session'),
      closeTo(0.8, 1e-9),
      reason: 'the released read succeeds with a real machine word',
    );
    await pumpEventQueue(times: 50);

    expect(session.transport.heldCalFlowEstResponses, 1);
    expect(session.transport.heldCalFlowEstResponseWord, 800);
    expect(
      session.transport.calFlowEstReads,
      readsWhileHeld,
      reason:
          'the observation queued before the end must not dispatch a read '
          'for the ended session',
    );
    expect(
      session.transport.reconnectAttempts,
      1,
      reason: 'no further reconnect may be provoked by the ended session',
    );
    expect(session.de1.cachedFlowEstimation, isNull);
    expect(session.transport.calFlowEstWrites, isEmpty);
  });

  test('an obsolete observation queued before the session ends cannot '
      'recover from its own timeout and adopt the ended epoch', () async {
    final session = await _connect();
    expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));

    session.transport.holdCalFlowEstReads = true;
    final heldGet = session.de1.getFlowEstimation();
    await _within(
      session.transport.calFlowEstReadEntered.future,
      'the ordinary calibration read that owns the MMR gate',
    );
    final readsWhileHeld = session.transport.calFlowEstReads;

    session.transport.timeoutNextRequestedStateWrite = true;
    await _within(
      session.de1.requestState(MachineState.sleeping),
      'the non-MMR BLE timeout recovery',
    );
    expect(session.transport.reconnectAttempts, 1);
    expect(
      session.transport.calFlowEstReads,
      readsWhileHeld,
      reason: 'the automatic observation is queued behind the held gate',
    );

    await _within(session.de1.onDisconnect(), 'the session to end');

    session.transport.timeoutNextMmrRead();

    session.transport.machineRawCalFlowEst = 800;
    session.transport.holdCalFlowEstReads = false;
    session.transport.releaseCalFlowEstRead();
    await _within(
      session.transport.heldCalFlowEstReadSettled.future,
      'the released ordinary read',
    );
    expect(
      await _within(heldGet, 'the ordinary read that outlived its session'),
      closeTo(0.8, 1e-9),
      reason: 'the released read succeeds with a real machine word',
    );
    await pumpEventQueue(times: 400);

    expect(session.transport.heldCalFlowEstResponses, 1);
    expect(session.transport.heldCalFlowEstResponseWord, 800);
    expect(
      session.transport.calFlowEstReads,
      readsWhileHeld,
      reason:
          'the obsolete observation must not dispatch, so its own timeout '
          'cannot start a recovery for the ended session',
    );
    expect(
      session.transport.pendingReadTimeouts,
      1,
      reason: 'no calibration read consumed the armed timeout',
    );
    expect(
      session.transport.reconnectAttempts,
      1,
      reason: 'a skipped observation cannot reconnect for the ended session',
    );
    expect(session.de1.cachedFlowEstimation, isNull);
    expect(session.transport.calFlowEstWrites, isEmpty);
  });

  test('a recovered explicit write keeps its ACK when its queued follow-up '
      'observation is obsolete', () async {
    final session = await _connect();
    expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));

    session.transport.holdCalFlowEstReads = true;
    session.transport.holdNextMmrWrite = true;
    session.transport.timeoutNextMmrWrite();
    final write = session.de1.setFlowEstimation(1.5);
    await _within(
      session.transport.mmrWriteDispatched.future,
      'the calibration write to be dispatched',
    );

    var acknowledged = false;
    final writeSettled = write.then(
      (_) => acknowledged = true,
      onError: (Object _) => acknowledged = false,
    );
    unawaited(writeSettled);
    session.transport.releaseMmrWrite();
    await _within(
      session.transport.calFlowEstReadEntered.future,
      'the observation that holds the gate after the write is acknowledged',
    );
    await pumpEventQueue(times: 20);

    final readsWhileHeld = session.transport.calFlowEstReads;
    expect(session.transport.calFlowEstWrites, [
      1500,
      1500,
    ], reason: 'the recovered write is acknowledged on the wire');
    expect(
      readsWhileHeld,
      2,
      reason:
          'only the connect read and the gate-holding observation dispatch; '
          'the follow-up observation is still parked at the gate',
    );
    expect(
      acknowledged,
      isFalse,
      reason:
          'the write stays pending on its queued follow-up observation, which '
          'is the only queue entry that can keep it from completing',
    );

    await _within(session.de1.onDisconnect(), 'the session to end');

    session.transport.machineRawCalFlowEst = 800;
    session.transport.holdCalFlowEstReads = false;
    session.transport.releaseCalFlowEstRead();
    await _within(
      session.transport.heldCalFlowEstReadSettled.future,
      'the released gate owner read',
    );
    await _within(write, 'the calibration write whose session ended');
    await pumpEventQueue(times: 50);

    expect(session.transport.calFlowEstWrites, [1500, 1500]);
    expect(
      session.transport.calFlowEstReads,
      readsWhileHeld,
      reason:
          'the follow-up observation queued for the ended session must not '
          'dispatch a read',
    );
    expect(session.transport.reconnectAttempts, 1);
    expect(session.de1.cachedFlowEstimation, isNull);
  });

  test('a timeout raised by a held dispatch that outlived its session cannot '
      'start a recovery that adopts the ended epoch', () async {
    final session = await _connect();
    expect(session.de1.cachedFlowEstimation, closeTo(1.0, 1e-9));

    session.transport.holdCalFlowEstReads = true;
    final ordinary = session.de1.getFlowEstimation();
    await _within(
      session.transport.calFlowEstReadEntered.future,
      'the ordinary calibration read',
    );
    final readsWhileHeld = session.transport.calFlowEstReads;

    await _within(session.de1.onDisconnect(), 'the session to end');

    session.transport.timeoutReleasedCalFlowEstReads = true;
    session.transport.machineRawCalFlowEst = 800;
    session.transport.holdCalFlowEstReads = false;
    session.transport.releaseCalFlowEstRead();
    await _within(
      session.transport.heldCalFlowEstReadSettled.future,
      'the released ordinary read',
    );
    expect(
      await _within(ordinary, 'the ordinary read whose dispatch timed out'),
      closeTo(0.8, 1e-9),
      reason: 'the retried dispatch still delivers the machine word',
    );
    await pumpEventQueue(times: 100);

    expect(session.transport.reconnectAttempts, 1);
    expect(
      session.transport.calFlowEstReads,
      readsWhileHeld + 1,
      reason:
          'the transport retry of the caller\'s own read is the only dispatch '
          'after the end; the ended session observes nothing',
    );
    expect(
      session.de1.cachedFlowEstimation,
      isNull,
      reason: 'the ended session cannot be repopulated by its own recovery',
    );
    expect(session.transport.calFlowEstWrites, isEmpty);
  });
}
