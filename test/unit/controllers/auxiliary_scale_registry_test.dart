import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/scan_report.dart';
import 'package:rxdart/rxdart.dart';

class _Scale implements Scale {
  _Scale(this.deviceId);

  @override
  final String deviceId;
  final BehaviorSubject<ConnectionState> _states = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final StreamController<ScaleSnapshot> _snapshots =
      StreamController.broadcast();
  final Completer<void> connectStarted = Completer<void>();
  Completer<void>? allowConnect;
  Completer<void>? disconnectGate;
  bool disconnected = false;
  bool connectCompleted = false;
  bool disconnectBeforeConnect = false;
  int tareCount = 0;

  @override
  String get name => deviceId;
  @override
  DeviceType get type => DeviceType.scale;
  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;
  @override
  TransportType get transportType => TransportType.unknown;
  @override
  Stream<ConnectionState> get connectionState => _states.stream;
  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshots.stream;

  @override
  Future<void> onConnect() async {
    if (!connectStarted.isCompleted) connectStarted.complete();
    final wait = allowConnect;
    if (wait != null) await wait.future;
    _states.add(ConnectionState.connected);
    connectCompleted = true;
  }

  @override
  Future<void> disconnect() async {
    if (!connectCompleted) disconnectBeforeConnect = true;
    disconnected = true;
    _states.add(ConnectionState.disconnected);
    await disconnectGate?.future;
  }

  @override
  Future<void> tare() async => tareCount++;
  @override
  Future<void> sleepDisplay() async {}
  @override
  Future<void> wakeDisplay() async {}
  @override
  Future<void> startTimer() async {}
  @override
  Future<void> stopTimer() async {}
  @override
  Future<void> resetTimer() async {}

  void emitSnapshot(double weight) => _snapshots.add(
    ScaleSnapshot(
      timestamp: DateTime.utc(2026, 9, 14),
      weight: weight,
      batteryLevel: 50,
    ),
  );
}

class _ThrowingHandoffScale extends _Scale implements ScaleSnapshotHandoff {
  _ThrowingHandoffScale(super.deviceId);

  @override
  void activateSnapshots() => throw StateError('handoff failed');
}

void main() {
  test('two auxiliary sessions keep snapshots and tare independent', () async {
    final registry = AuxiliaryScaleRegistry();
    final first = _Scale('A');
    final second = _Scale('B');

    expect(
      (await registry.connect(first, isPrimaryClaimed: (_) => false)).success,
      isTrue,
    );
    expect(
      (await registry.connect(second, isPrimaryClaimed: (_) => false)).success,
      isTrue,
    );

    final snapshots = <ScaleSnapshot>[];
    final sub = registry.connectionFor('B')!.snapshots.listen(snapshots.add);
    second.emitSnapshot(2);
    await expectLater(Future<void>.delayed(Duration.zero), completes);
    expect(snapshots.single.weight, 2);

    await registry.connectionFor('A')!.scale.tare();
    expect(first.tareCount, 1);
    expect(second.tareCount, 0);
    await sub.cancel();
    await registry.dispose();
  });

  test('a new registry does not restore auxiliary sessions', () async {
    final registry = AuxiliaryScaleRegistry();
    final scale = _Scale('restart-scale');
    expect(
      (await registry.connect(scale, isPrimaryClaimed: (_) => false)).success,
      isTrue,
    );
    await registry.dispose();

    final restarted = AuxiliaryScaleRegistry();
    expect(restarted.connectedDeviceIds, isEmpty);
    expect(restarted.connectionFor('restart-scale'), isNull);
    await restarted.dispose();
  });

  test('cancelled pending connect cannot publish a late session', () async {
    final registry = AuxiliaryScaleRegistry();
    final firstGate = Completer<void>();
    final pending = _Scale('A')..allowConnect = firstGate;
    final first = registry.connect(pending, isPrimaryClaimed: (_) => false);
    await pending.connectStarted.future;

    expect((await registry.disconnect('A')).success, isTrue);
    pending.allowConnect = null;
    final retry = registry.connect(pending, isPrimaryClaimed: (_) => false);
    expect((await retry).outcome, ConnectionOutcome.conflict);
    firstGate.complete();
    expect((await first).outcome, ConnectionOutcome.conflict);
    expect(registry.connectionFor('A'), isNull);
    expect(pending.disconnected, isTrue);

    final fresh = _Scale('A');
    expect(
      (await registry.connect(fresh, isPrimaryClaimed: (_) => false)).success,
      isTrue,
    );
    await registry.dispose();
  });

  test(
    'pending cancellation waits for delayed connect before cleanup',
    () async {
      final registry = AuxiliaryScaleRegistry();
      final gate = Completer<void>();
      final scale = _Scale('delayed-cleanup')..allowConnect = gate;
      final connection = registry.connect(
        scale,
        isPrimaryClaimed: (_) => false,
      );
      await scale.connectStarted.future;

      final disconnect = registry.disconnect(scale.deviceId);
      await Future<void>.delayed(Duration.zero);
      expect(scale.disconnected, isFalse);
      expect(registry.isReserved(scale.deviceId), isTrue);

      gate.complete();
      expect((await connection).outcome, ConnectionOutcome.conflict);
      expect((await disconnect).success, isTrue);
      expect(scale.disconnected, isTrue);
      expect(scale.disconnectBeforeConnect, isFalse);
      expect(registry.isReserved(scale.deviceId), isFalse);
      await registry.dispose();
    },
  );

  test('handoff setup failure releases the session and transport', () async {
    final registry = AuxiliaryScaleRegistry();
    final scale = _ThrowingHandoffScale('handoff-failure');

    final result = await registry.connect(
      scale,
      isPrimaryClaimed: (_) => false,
    );

    expect(result.outcome, ConnectionOutcome.failed);
    expect(registry.isReserved(scale.deviceId), isFalse);
    expect(registry.connectionFor(scale.deviceId), isNull);
    expect(scale.disconnected, isTrue);
    await registry.dispose();
  });

  test(
    'dispose cancels pending connect without publishing a session',
    () async {
      final registry = AuxiliaryScaleRegistry();
      final gate = Completer<void>();
      final scale = _Scale('disposed-scale')..allowConnect = gate;
      final connection = registry.connect(
        scale,
        isPrimaryClaimed: (_) => false,
      );
      await scale.connectStarted.future;
      await registry.dispose();
      gate.complete();

      expect((await connection).outcome, ConnectionOutcome.conflict);
      expect(registry.connectionFor('disposed-scale'), isNull);
      expect(scale.disconnected, isTrue);
    },
  );

  test(
    'closing auxiliary reservation blocks reuse until cleanup settles',
    () async {
      final registry = AuxiliaryScaleRegistry();
      final first = _Scale('closing-scale')..disconnectGate = Completer<void>();
      expect(
        (await registry.connect(first, isPrimaryClaimed: (_) => false)).success,
        isTrue,
      );

      final disconnect = registry.disconnect('closing-scale');
      await Future<void>.delayed(Duration.zero);
      final blocked = await registry.connect(
        _Scale('closing-scale'),
        isPrimaryClaimed: (_) => false,
      );
      expect(blocked.outcome, ConnectionOutcome.conflict);
      first.disconnectGate!.complete();
      expect((await disconnect).success, isTrue);
      expect(
        (await registry.connect(
          _Scale('closing-scale'),
          isPrimaryClaimed: (_) => false,
        )).success,
        isTrue,
      );
      await registry.dispose();
    },
  );

  test('auxiliary weights never enter the primary scale stream', () async {
    final primaryController = ScaleController();
    final registry = AuxiliaryScaleRegistry();
    final primary = _Scale('primary');
    final auxiliary = _Scale('auxiliary');
    await primaryController.connectToScale(primary);
    await registry.connect(auxiliary, isPrimaryClaimed: (_) => false);

    final primarySnapshots = <WeightSnapshot>[];
    final subscription = primaryController.weightSnapshot.listen(
      primarySnapshots.add,
    );
    auxiliary.emitSnapshot(99);
    primary.emitSnapshot(1);
    await Future<void>.delayed(Duration.zero);

    expect(primarySnapshots, hasLength(1));
    expect(primarySnapshots.single.weight, 1);
    await subscription.cancel();
    primaryController.dispose();
    await registry.dispose();
  });
}
