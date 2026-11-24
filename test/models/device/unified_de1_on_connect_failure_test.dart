import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/machine.dart';

import '../../helpers/on_connect_failure_transport.dart';

const _watchdog = Duration(seconds: 5);

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

UnifiedDe1 _build(OnConnectFailureTransport transport) => UnifiedDe1(
  transport: transport,
  calibrationTimeout: const Duration(milliseconds: 200),
);

int _requestedStateWrites(OnConnectFailureTransport transport) => transport
    .writes
    .where((write) => write.characteristicUUID == Endpoint.requestedState.uuid)
    .length;

void main() {
  test('a re-connect whose transport connect fails cannot hand a held '
      'operation\'s recovery to the failed session', () async {
    final transport = OnConnectFailureTransport()..machineRawCalFlowEst = 1000;
    final de1 = _build(transport);
    addTearDown(de1.dispose);
    await _within(de1.onConnect(), 'the first connect');
    expect(de1.cachedFlowEstimation, closeTo(1.0, 1e-9));
    final readsAfterConnect = transport.calFlowEstReads;

    transport.holdNextRequestedStateWrite = true;
    final held = de1.requestState(MachineState.sleeping);
    await _within(
      transport.requestedStateWriteDispatched.future,
      'the held requestedState write',
    );

    transport.pendingConnectFailures = 1;
    await expectLater(
      _within(de1.onConnect(), 'the re-connect'),
      throwsA(isA<StateError>()),
    );

    expect(
      transport.pendingConnectFailures,
      0,
      reason: 'the injected failure was consumed by the re-connect',
    );
    expect(
      transport.connectCalls,
      1,
      reason: 'the re-connect fails before the link is established',
    );
    expect(de1.cachedFlowEstimation, isNull);
    expect(transport.calFlowEstReads, readsAfterConnect);

    transport.releaseRequestedStateWrite();
    await _within(held, 'the held operation and its transparent recovery');
    await pumpEventQueue(times: 50);

    expect(transport.reconnectAttempts, 1);
    expect(_requestedStateWrites(transport), 2);
    expect(
      transport.calFlowEstReads,
      readsAfterConnect,
      reason:
          'a session that never connected must not run an automatic '
          'calibration read for the failed re-connect',
    );
    expect(
      de1.cachedFlowEstimation,
      isNull,
      reason: 'the failed re-connect cannot publish a multiplier',
    );
    expect(transport.calFlowEstWrites, isEmpty);
  });

  test('a first connect whose handshake read fails cannot hand a held '
      'operation\'s recovery to the failed session', () async {
    final transport = OnConnectFailureTransport()..machineRawCalFlowEst = 1000;
    final de1 = _build(transport);
    addTearDown(de1.dispose);

    transport.holdNextRequestedStateWrite = true;
    final held = de1.requestState(MachineState.sleeping);
    await _within(
      transport.requestedStateWriteDispatched.future,
      'the held requestedState write',
    );

    transport.failMmrReadsForAddresses.add(MMRItem.v13Model.address);
    await expectLater(
      _within(de1.onConnect(), 'the first connect'),
      throwsA(isA<StateError>()),
    );

    expect(
      transport.connectCalls,
      1,
      reason: 'the handshake fails after the transport connected',
    );
    expect(
      transport.readCounts[MMRItem.v13Model.address],
      1,
      reason: 'the failing identity read is the handshake read',
    );
    expect(
      transport.calFlowEstReads,
      0,
      reason: 'the handshake fails before the multiplier is read',
    );
    expect(de1.cachedFlowEstimation, isNull);

    transport.failMmrReadsForAddresses.remove(MMRItem.v13Model.address);
    transport.releaseRequestedStateWrite();
    await _within(held, 'the held operation and its transparent recovery');
    await pumpEventQueue(times: 50);

    expect(transport.reconnectAttempts, 1);
    expect(_requestedStateWrites(transport), 2);
    expect(
      transport.calFlowEstReads,
      0,
      reason:
          'a session whose handshake failed must not run an automatic '
          'calibration read for it',
    );
    expect(
      de1.cachedFlowEstimation,
      isNull,
      reason: 'a failed first connect cannot publish a multiplier',
    );
    expect(transport.calFlowEstWrites, isEmpty);
  });

  test('a superseded connect that fails late cannot clear the session that '
      'replaced it', () async {
    final transport = OnConnectFailureTransport()..machineRawCalFlowEst = 1000;
    final de1 = _build(transport);
    addTearDown(de1.dispose);

    transport.delayNextConnectFailure = true;
    final superseded = de1.onConnect();
    await _within(
      transport.connectDispatched.future,
      'the superseded connect to be dispatched',
    );

    await _within(de1.onConnect(), 'the replacement connect');
    expect(de1.cachedFlowEstimation, closeTo(1.0, 1e-9));
    final readsAfterReplacement = transport.calFlowEstReads;
    expect(readsAfterReplacement, 1);
    expect(
      transport.connectCalls,
      1,
      reason: 'only the replacement connect reached the link',
    );

    final supersededFailure = expectLater(
      _within(superseded, 'the superseded connect failure'),
      throwsA(isA<StateError>()),
    );
    transport.releaseDelayedConnectFailure();
    await _within(supersededFailure, 'the superseded connect to fail');

    expect(
      de1.cachedFlowEstimation,
      closeTo(1.0, 1e-9),
      reason: 'a failed connect cannot clear the session that replaced it',
    );
    expect(
      transport.calFlowEstReads,
      readsAfterReplacement,
      reason: 'the failed connect cannot run a calibration read',
    );
    expect(transport.connectCalls, 1);

    transport.machineRawCalFlowEst = 800;
    transport.timeoutNextRequestedStateWrite = true;
    await _within(
      de1.requestState(MachineState.sleeping),
      'the replacement session recovery',
    );

    expect(transport.reconnectAttempts, 1);
    await _pumpUntil(
      () => de1.cachedFlowEstimation != null,
      'the replacement session multiplier refresh',
    );
    expect(de1.cachedFlowEstimation, closeTo(0.8, 1e-9));
    expect(
      transport.calFlowEstReads,
      greaterThan(readsAfterReplacement),
      reason: 'the refreshed multiplier comes from a fresh machine read',
    );
    expect(
      transport.calFlowEstWrites,
      isEmpty,
      reason: 'the recovered session is read-only for calFlowEst',
    );
    expect(
      await _within(de1.getFlowEstimation(), 'the multiplier read'),
      closeTo(0.8, 1e-9),
    );
    expect(de1.cachedFlowEstimation, closeTo(0.8, 1e-9));
  });
}
