import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

class _TrackingScale implements Scale {
  @override
  final String deviceId;
  _TrackingScale(this.deviceId);

  final _conn = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.discovered,
  );
  final _snap = BehaviorSubject<ScaleSnapshot>();
  bool disconnected = false;

  @override
  String get name => deviceId;
  @override
  DeviceType get type => DeviceType.scale;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;
  @override
  Stream<ConnectionState> get connectionState => _conn.stream;
  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snap.stream;

  @override
  Future<void> onConnect() async => _conn.add(ConnectionState.connected);
  @override
  Future<void> disconnect() async {
    disconnected = true;
    _conn.add(ConnectionState.disconnected);
  }

  @override
  Future<void> tare() async {}

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

  void emitAt(DateTime t, double weight, {double? flow}) => _snap.add(
    ScaleSnapshot(timestamp: t, weight: weight, batteryLevel: 50, flow: flow),
  );
}

class _HandoffTrackingScale extends _TrackingScale
    implements TransportHandoffScale {
  _HandoffTrackingScale(super.deviceId);
  bool handoffReleased = false;

  @override
  Future<void> disconnectForHandoff() async {
    handoffReleased = true;
    _conn.add(ConnectionState.disconnected);
  }
}

class _FailingScale extends _TrackingScale {
  _FailingScale(super.deviceId);

  @override
  Future<void> onConnect() async => throw StateError('connect failed');

  void emitSnapshot() => _snap.add(
    ScaleSnapshot(timestamp: DateTime.now(), weight: 1.0, batteryLevel: 100),
  );
}

void main() {
  test('uses device-provided flow unchanged', () async {
    final controller = ScaleController();
    final scale = _TrackingScale('A');
    await controller.connectToScale(scale);
    final snapshot = controller.weightSnapshot.first;

    scale.emitAt(DateTime.utc(2026, 8, 11), 12.0, flow: 1.75);

    expect((await snapshot).weightFlow, 1.75);
    expect(controller.currentWeightSnapshot!.controlWeightFlow, 1.75);
    controller.dispose();
  });

  test('connect forwards connected once', () async {
    final controller = ScaleController();
    final scale = _TrackingScale('A');
    final states = <ConnectionState>[];
    final subscription = controller.connectionState.listen(states.add);

    await controller.connectToScale(scale);
    await Future<void>.delayed(Duration.zero);

    expect(
      states.where((state) => state == ConnectionState.connected),
      hasLength(1),
    );

    await subscription.cancel();
    controller.dispose();
  });

  test('adopt forwards connected once', () async {
    final controller = ScaleController();
    final scale = _TrackingScale('A');
    final states = <ConnectionState>[];
    final subscription = controller.connectionState.listen(states.add);
    await scale.onConnect();

    await controller.adoptScale(scale);
    await Future<void>.delayed(Duration.zero);

    expect(
      states.where((state) => state == ConnectionState.connected),
      hasLength(1),
    );

    await subscription.cancel();
    controller.dispose();
  });

  test('weight snapshots cache their scale connection generation', () async {
    final controller = ScaleController();
    final scale = _TrackingScale('A');
    final frames = <WeightSnapshot>[];
    final subscription = controller.weightSnapshot.listen(frames.add);

    await controller.connectToScale(scale);
    scale.emitAt(DateTime.now(), 40);
    await Future<void>.delayed(Duration.zero);
    final firstGeneration = frames.single.connectionGeneration;
    expect(controller.currentWeightSnapshot, same(frames.single));

    await controller.connectToScale(scale);
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentWeightSnapshot, isNull);
    expect(frames, hasLength(1));

    scale.emitAt(DateTime.now(), 2);
    await Future<void>.delayed(Duration.zero);

    expect(frames, hasLength(2));
    expect(controller.currentWeightSnapshot, same(frames.last));
    expect(frames.last.connectionGeneration, controller.connectionGeneration);
    expect(frames.last.connectionGeneration, isNot(firstGeneration));

    await subscription.cancel();
    controller.dispose();
  });

  test('a scale whose onConnect throws surfaces as disconnected and leaks no '
      'snapshot subscription', () async {
    final controller = ScaleController();
    final scale = _FailingScale('W');

    await expectLater(
      controller.connectToScale(scale),
      throwsA(isA<StateError>()),
    );

    expect(
      () => controller.connectedScale(),
      throwsA(isA<DeviceNotConnectedException>()),
    );
    expect(controller.currentConnectionState, ConnectionState.disconnected);

    final frames = <WeightSnapshot>[];
    final sub = controller.weightSnapshot.listen(frames.add);
    scale.emitSnapshot();
    await Future.delayed(Duration.zero);
    expect(
      frames,
      isEmpty,
      reason:
          'a failed connect must not leave the snapshot subscription '
          'live',
    );

    await sub.cancel();
    controller.dispose();
  });

  test('switching away from a handoff-capable scale releases it WITHOUT '
      'power-off (uses disconnectForHandoff)', () async {
    final controller = ScaleController();
    final a = _HandoffTrackingScale('A');
    final b = _TrackingScale('B');

    await controller.connectToScale(a);
    await controller.connectToScale(b);

    expect(
      a.handoffReleased,
      isTrue,
      reason: 'a transport switch must use the non-power-off handoff path',
    );
    expect(
      a.disconnected,
      isFalse,
      reason:
          'the destructive disconnect() (power-off) must NOT be used '
          'when switching the active scale',
    );

    controller.dispose();
  });

  test(
    'connecting a new scale disconnects the previously-connected scale',
    () async {
      final controller = ScaleController();
      final a = _TrackingScale('A');
      final b = _TrackingScale('B');

      await controller.connectToScale(a);
      expect(controller.connectedScale().deviceId, 'A');
      expect(a.disconnected, isFalse);

      await controller.connectToScale(b);
      expect(controller.connectedScale().deviceId, 'B');
      expect(
        a.disconnected,
        isTrue,
        reason: 'the previous scale must be disconnected (one active scale)',
      );
      expect(b.disconnected, isFalse);

      controller.dispose();
    },
  );

  test('reconnecting the SAME scale does not disconnect it', () async {
    final controller = ScaleController();
    final a = _TrackingScale('A');

    await controller.connectToScale(a);
    await controller.connectToScale(a);
    expect(
      a.disconnected,
      isFalse,
      reason: 'same-device reconnect should not toggle disconnect',
    );

    controller.dispose();
  });

  test('public flow stays smooth on the native shot trace', () async {
    final controller = ScaleController();
    final scale = _TrackingScale('A');
    await controller.connectToScale(scale);

    final frames = <WeightSnapshot>[];
    final sub = controller.weightSnapshot.listen(frames.add);
    final rows = File(
      'test/fixtures/shot1_native_trace.csv',
    ).readAsLinesSync().skip(1);
    for (final row in rows) {
      final values = row.split(',');
      scale.emitAt(
        DateTime.fromMillisecondsSinceEpoch(int.parse(values[0]), isUtc: true),
        double.parse(values[1]),
      );
    }
    await Future.delayed(Duration.zero);

    final flows = frames.skip(10).map((frame) => frame.weightFlow).toList();
    final meanDelta =
        [for (var i = 1; i < flows.length; i++) (flows[i] - flows[i - 1]).abs()]
            .reduce((a, b) => a + b) /
        (flows.length - 1);
    expect(meanDelta, lessThanOrEqualTo(0.12));

    final controlFlows = frames
        .skip(10)
        .map((frame) => frame.controlWeightFlow)
        .toList();
    final controlMeanDelta =
        [
          for (var i = 1; i < controlFlows.length; i++)
            (controlFlows[i] - controlFlows[i - 1]).abs(),
        ].reduce((a, b) => a + b) /
        (controlFlows.length - 1);
    expect(controlMeanDelta, closeTo(0.2597772268251356, 1e-9));

    await sub.cancel();
    controller.dispose();
  });

  test('runtime smoothing update resets only display flow', () async {
    final controller = ScaleController();
    final scale = _TrackingScale('A');
    await controller.connectToScale(scale);
    final frames = <WeightSnapshot>[];
    final sub = controller.weightSnapshot.listen(frames.add);
    final t0 = DateTime.utc(2026, 7, 22);

    for (var i = 0; i < 20; i++) {
      scale.emitAt(t0.add(Duration(milliseconds: i * 100)), i * 0.5);
    }
    await Future.delayed(Duration.zero);
    expect(frames.last.weightFlow, greaterThan(0));
    expect(frames.last.controlWeightFlow, greaterThan(0));

    controller.setFlowSmoothing(windowMs: 800, movingAverageSamples: 6);
    scale.emitAt(t0.add(const Duration(seconds: 2)), 10.0);
    await Future.delayed(Duration.zero);

    expect(controller.flowSmoothingWindowMs, 800);
    expect(controller.flowSmoothingSamples, 6);
    expect(frames.last.weightFlow, 0);
    expect(frames.last.controlWeightFlow, greaterThan(0));

    await sub.cancel();
    controller.dispose();
  });

  test('control flow is internal and falls back for historical snapshots', () {
    final timestamp = DateTime.utc(2026, 7, 22);
    final historical = WeightSnapshot.fromJson({
      'timestamp': timestamp.toIso8601String(),
      'weight': 12.3,
      'weightFlow': 4.5,
      'battery': 50,
      'timerValue': null,
    });
    final live = WeightSnapshot(
      timestamp: timestamp,
      weight: 12.3,
      weightFlow: 1.2,
      controlWeightFlow: 4.5,
    );

    expect(historical.controlWeightFlow, 4.5);
    expect(live.controlWeightFlow, 4.5);
    expect(live.toJson(), isNot(contains('controlWeightFlow')));
  });

  test('tare suppresses the flow transient for one smoothing window without '
      'touching weight', () async {
    final controller = ScaleController();
    final scale = _TrackingScale('A');
    await controller.connectToScale(scale);

    final frames = <WeightSnapshot>[];
    final sub = controller.weightSnapshot.listen(frames.add);

    final t0 = DateTime(2026, 1, 1, 12, 0, 0);
    scale.emitAt(t0, 10.0);
    scale.emitAt(t0.add(const Duration(milliseconds: 100)), 14.0);
    await Future.delayed(Duration.zero);
    expect(
      frames.last.weightFlow,
      greaterThan(0),
      reason: 'real flow flows before any tare',
    );

    await controller.tare();

    scale.emitAt(t0.add(const Duration(milliseconds: 200)), 0.0);
    scale.emitAt(t0.add(const Duration(milliseconds: 500)), 0.0);
    await Future.delayed(Duration.zero);
    final settleFrames = frames
        .where(
          (f) => f.timestamp.isAfter(t0.add(const Duration(milliseconds: 150))),
        )
        .toList();
    expect(settleFrames, isNotEmpty);
    expect(
      settleFrames.every((f) => f.weightFlow == 0),
      isTrue,
      reason: 'the post-tare flow transient must be suppressed',
    );
    expect(
      frames.last.weight,
      0.0,
      reason: 'weight itself is never suppressed by tare',
    );

    scale.emitAt(t0.add(const Duration(milliseconds: 800)), 4.0);
    scale.emitAt(t0.add(const Duration(milliseconds: 900)), 8.0);
    await Future.delayed(Duration.zero);
    expect(frames.last.weight, 8.0);
    expect(
      frames.last.weightFlow,
      greaterThan(0),
      reason: 'real flow resumes once the window has cleared',
    );

    await sub.cancel();
    controller.dispose();
  });
}
