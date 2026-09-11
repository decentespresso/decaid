import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/connection_selection_session.dart';
import 'package:reaprime/src/controllers/connection/scan_report_builder.dart';
import 'package:reaprime/src/controllers/dosing_scale_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';

class _FakeScale extends Scale {
  _FakeScale(this.deviceId);

  @override
  final String deviceId;

  final _connection = StreamController<ConnectionState>.broadcast();
  final _snapshots = StreamController<ScaleSnapshot>.broadcast();

  ConnectionState _state = ConnectionState.disconnected;
  int tareCount = 0;
  int disconnectCount = 0;

  @override
  String get name => 'Fake $deviceId';

  @override
  DeviceType get type => DeviceType.scale;

  @override
  DeviceImplementation get implementation => DeviceImplementation.decentScale;

  @override
  TransportType get transportType => TransportType.ble;

  @override
  Stream<ConnectionState> get connectionState async* {
    yield _state;
    yield* _connection.stream;
  }

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshots.stream;

  @override
  Future<void> onConnect() async => emitConnection(ConnectionState.connected);

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    emitConnection(ConnectionState.disconnected);
  }

  @override
  Future<void> tare() async => tareCount++;

  @override
  Future<void> sleepDisplay() async {}

  @override
  Future<void> wakeDisplay() async {}

  void emitConnection(ConnectionState state) {
    _state = state;
    _connection.add(state);
  }

  void emitWeight(double grams) {
    _snapshots.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: grams,
        batteryLevel: 80,
      ),
    );
  }

  Future<void> close() async {
    await _connection.close();
    await _snapshots.close();
  }
}

ConnectionSelectionSession _session(
  List<Scale> scales, {
  String? dosingScaleId,
}) {
  return ConnectionSelectionSession(
    machines: const [],
    scales: scales,
    preferredMachineId: null,
    preferredScaleId: null,
    dosingScaleId: dosingScaleId,
    scanReport: ScanReportBuilder(scanStartTime: DateTime.now()),
  );
}

void main() {
  group('brewing selection and the dosing scale', () {
    test('refuses the scale reserved for dosing', () {
      final brew = _FakeScale('brew-1');
      final dosing = _FakeScale('dosing-1');
      final session = _session([brew, dosing], dosingScaleId: 'dosing-1');

      expect(session.acceptsScale(brew), isTrue);
      expect(session.acceptsScale(dosing), isFalse);
      expect(session.isDosingScale('dosing-1'), isTrue);
    });

    test('accepts every scale when no dosing scale is set', () {
      final one = _FakeScale('scale-1');
      final two = _FakeScale('scale-2');
      final session = _session([one, two]);

      expect(session.acceptsScale(one), isTrue);
      expect(session.acceptsScale(two), isTrue);
      expect(session.isDosingScale('scale-1'), isFalse);
    });

    test('a dosing id naming no scanned scale changes nothing', () {
      final one = _FakeScale('scale-1');
      final session = _session([one], dosingScaleId: 'not-in-range');

      expect(session.acceptsScale(one), isTrue);
    });

    test('an inactive session accepts nothing, dosing id or not', () {
      final one = _FakeScale('scale-1');
      final session = _session([one], dosingScaleId: 'dosing-1');
      session.invalidate();

      expect(session.acceptsScale(one), isFalse);
    });
  });

  group('DosingScaleController', () {
    late DosingScaleController controller;
    late _FakeScale scale;

    setUp(() {
      controller = DosingScaleController();
      scale = _FakeScale('dosing-1');
    });

    tearDown(() async {
      controller.dispose();
      await scale.close();
    });

    test('starts disconnected and refuses to hand out a scale', () {
      expect(controller.currentConnectionState, ConnectionState.disconnected);
      expect(controller.currentSnapshot, isNull);
      expect(
        () => controller.connectedScale(),
        throwsA(isA<DeviceNotConnectedException>()),
      );
    });

    test('connects, then reports weight on its own stream', () async {
      await controller.connectToScale(scale);
      expect(controller.lastConnectedDeviceId, 'dosing-1');

      final seen = <double>[];
      final sub = controller.snapshot.listen((s) => seen.add(s.weight));
      scale.emitWeight(18.2);
      scale.emitWeight(18.4);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, [18.2, 18.4]);
      expect(controller.currentSnapshot?.weight, 18.4);
    });

    test('tare reaches the scale it is connected to', () async {
      await controller.connectToScale(scale);
      await controller.tare();
      expect(scale.tareCount, 1);
    });

    test('forgets the reading when the scale drops', () async {
      await controller.connectToScale(scale);
      scale.emitWeight(18.2);
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentSnapshot, isNotNull);

      scale.emitConnection(ConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentSnapshot, isNull);
    });

    test('swapping scales releases the previous one', () async {
      final other = _FakeScale('dosing-2');
      addTearDown(other.close);

      await controller.connectToScale(scale);
      await controller.connectToScale(other);

      expect(scale.disconnectCount, 1);
      expect(controller.lastConnectedDeviceId, 'dosing-2');
    });

    test('reconnecting the same scale does not disconnect it', () async {
      await controller.connectToScale(scale);
      await controller.connectToScale(scale);

      expect(scale.disconnectCount, 0);
    });

    test('each attach is a new generation', () async {
      final first = controller.connectionGeneration;
      await controller.connectToScale(scale);
      expect(controller.connectionGeneration, greaterThan(first));
    });
  });
}
