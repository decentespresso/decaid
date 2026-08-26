import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/hot_water_sequencer.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/mock_settings_service.dart';

class _EmptyDiscovery extends DeviceDiscoveryService {
  @override
  Stream<List<Device>> get devices => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
}

class _StubDe1Controller extends De1Controller {
  _StubDe1Controller({HotWaterData? hotWater})
    : _de1subj = BehaviorSubject.seeded(null),
      _hw = BehaviorSubject.seeded(
        hotWater ??
            HotWaterData(
              targetTemperature: 85,
              duration: 35,
              volume: 30,
              flow: 2.0,
            ),
      ),
      super(controller: DeviceController([_EmptyDiscovery()]));

  final BehaviorSubject<De1Interface?> _de1subj;
  final BehaviorSubject<HotWaterData> _hw;

  @override
  Stream<De1Interface?> get de1 => _de1subj.stream;
  @override
  Stream<HotWaterData> get hotWaterData => _hw.stream;
  @override
  Future<void> requestMachineState(MachineState state) {
    return _de1subj.value!.requestState(state);
  }

  void emitMachine(De1Interface? d) => _de1subj.add(d);
  void setHotWater(HotWaterData hw) => _hw.add(hw);
}

class _StubScaleController extends ScaleController {
  _StubScaleController({ConnectionState initial = ConnectionState.connected})
    : _conn = BehaviorSubject.seeded(initial);

  final BehaviorSubject<WeightSnapshot> _weights = BehaviorSubject();
  final BehaviorSubject<ConnectionState> _conn;
  int tareCount = 0;

  @override
  Stream<WeightSnapshot> get weightSnapshot => _weights.stream;
  @override
  Stream<ConnectionState> get connectionState => _conn.stream;
  @override
  ConnectionState get currentConnectionState => _conn.value;
  @override
  Future<void> tare() async {
    tareCount++;
  }

  void emitWeight(
    double weight, {
    double flow = 0,
    double? controlFlow,
    DateTime? at,
  }) {
    _weights.add(
      WeightSnapshot(
        timestamp: at ?? DateTime.now(),
        weight: weight,
        weightFlow: flow,
        controlWeightFlow: controlFlow,
      ),
    );
  }

  void setConnection(ConnectionState s) => _conn.add(s);

  @override
  void dispose() {
    _weights.close();
    _conn.close();
  }
}

class _TestMachine implements De1Interface {
  @override
  String get deviceId => 'test-machine';
  @override
  String get name => 'TestMachine';
  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

  @override
  TransportType get transportType => TransportType.unknown;

  final BehaviorSubject<MachineSnapshot> _snap = BehaviorSubject();
  @override
  Stream<MachineSnapshot> get currentSnapshot => _snap.stream;

  final List<MachineState> requested = [];
  @override
  Future<void> requestState(MachineState state) async {
    requested.add(state);
  }

  void emit(MachineSnapshot s) => _snap.add(s);

  @override
  Future<void> dispose() async => _snap.close();
  @override
  Stream<ConnectionState> get connectionState =>
      Stream.value(ConnectionState.connected);
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<bool> get ready => Stream<bool>.value(false);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

MachineSnapshot _snap(
  MachineState state, {
  MachineSubstate substate = MachineSubstate.pouring,
}) {
  return MachineSnapshot(
    timestamp: DateTime.now(),
    state: MachineStateSnapshot(state: state, substate: substate),
    flow: 0,
    pressure: 0,
    targetFlow: 0,
    targetPressure: 0,
    mixTemperature: 90,
    groupTemperature: 90,
    targetMixTemperature: 93,
    targetGroupTemperature: 93,
    profileFrame: 0,
    steamTemperature: 0,
  );
}

void main() {
  late _StubDe1Controller de1;
  late _StubScaleController scale;
  late SettingsController settings;
  late MockSettingsService settingsService;
  late HotWaterSequencer sequencer;
  late DateTime clock;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> build() async {
    sequencer = HotWaterSequencer(
      de1Controller: de1,
      scaleController: scale,
      settingsController: settings,
      now: () => clock,
    );
    await settle();
  }

  setUp(() async {
    clock = DateTime(2024, 1, 1, 12, 0, 0);
    de1 = _StubDe1Controller();
    scale = _StubScaleController();
    settingsService = MockSettingsService();
    settings = SettingsController(settingsService);
    await settings.loadSettings();
  });

  tearDown(() async {
    await sequencer.dispose();
    scale.dispose();
  });

  group('arming', () {
    test(
      'tares the scale and arms on entering hotWater when eligible',
      () async {
        await build();
        final m = _TestMachine();
        de1.emitMachine(m);
        await settle();
        m.emit(_snap(MachineState.hotWater));
        await settle();

        expect(scale.tareCount, 1);
        expect(sequencer.isArmed, isTrue);
        m.dispose();
      },
    );

    test('does not arm when the setting is off', () async {
      await settings.setStopHotWaterAtWeight(false);
      await build();
      final m = _TestMachine();
      de1.emitMachine(m);
      await settle();
      m.emit(_snap(MachineState.hotWater));
      await settle();

      expect(scale.tareCount, 0);
      expect(sequencer.isArmed, isFalse);
    });

    test('does not arm when no scale is connected', () async {
      scale.setConnection(ConnectionState.disconnected);
      await build();
      final m = _TestMachine();
      de1.emitMachine(m);
      await settle();
      m.emit(_snap(MachineState.hotWater));
      await settle();

      expect(scale.tareCount, 0);
      expect(sequencer.isArmed, isFalse);
    });

    test('does not arm in full gateway mode (skin owns the machine)', () async {
      await settings.updateGatewayMode(GatewayMode.full);
      await build();
      final m = _TestMachine();
      de1.emitMachine(m);
      await settle();
      m.emit(_snap(MachineState.hotWater));
      await settle();

      expect(scale.tareCount, 0);
      expect(sequencer.isArmed, isFalse);
    });

    test('does not arm when the target volume is zero', () async {
      de1 = _StubDe1Controller(
        hotWater: HotWaterData(
          targetTemperature: 85,
          duration: 35,
          volume: 0,
          flow: 2,
        ),
      );
      await build();
      final m = _TestMachine();
      de1.emitMachine(m);
      await settle();
      m.emit(_snap(MachineState.hotWater));
      await settle();

      expect(scale.tareCount, 0);
      expect(sequencer.isArmed, isFalse);
    });
  });

  group('stopping', () {
    Future<_TestMachine> armAndConfirmTare() async {
      final m = _TestMachine();
      de1.emitMachine(m);
      await settle();
      m.emit(_snap(MachineState.hotWater));
      await settle();
      scale.emitWeight(0, flow: 0, at: clock);
      await settle();
      return m;
    }

    test('requests idle once the weight reaches the target', () async {
      await build();
      final m = await armAndConfirmTare();

      clock = clock.add(const Duration(seconds: 1));
      scale.emitWeight(30, flow: 0, at: clock);
      await settle();

      expect(m.requested, contains(MachineState.idle));
      m.dispose();
    });

    test('projects weight with control flow', () async {
      await build();
      final m = await armAndConfirmTare();

      clock = clock.add(const Duration(seconds: 1));
      scale.emitWeight(29, flow: 0, controlFlow: 4, at: clock);
      await settle();

      expect(m.requested, contains(MachineState.idle));
      m.dispose();
    });

    test('does not stop before the tare-settle window elapses', () async {
      await build();
      final m = await armAndConfirmTare();

      clock = clock.add(const Duration(milliseconds: 100));
      scale.emitWeight(50, flow: 0, at: clock);
      await settle();

      expect(m.requested, isEmpty);
      m.dispose();
    });

    test(
      'waits for the post-tare zero before stopping (stale pre-tare weight)',
      () async {
        await build();
        final m = _TestMachine();
        de1.emitMachine(m);
        await settle();
        m.emit(_snap(MachineState.hotWater));
        await settle();

        clock = clock.add(const Duration(seconds: 1));
        scale.emitWeight(50, flow: 0, at: clock);
        await settle();
        expect(
          m.requested,
          isEmpty,
          reason: 'must not stop on an unconfirmed (pre-tare) reading',
        );

        scale.emitWeight(0, flow: 0, at: clock);
        await settle();
        clock = clock.add(const Duration(milliseconds: 200));
        scale.emitWeight(30, flow: 0, at: clock);
        await settle();
        expect(m.requested, contains(MachineState.idle));
        m.dispose();
      },
    );

    test('only requests idle once', () async {
      await build();
      final m = await armAndConfirmTare();

      clock = clock.add(const Duration(seconds: 1));
      scale.emitWeight(40, flow: 1, at: clock);
      await settle();
      scale.emitWeight(45, flow: 1, at: clock);
      await settle();

      expect(m.requested.where((s) => s == MachineState.idle).length, 1);
      m.dispose();
    });

    test('re-arms and stops again on a second consecutive dispense', () async {
      await build();
      final m = await armAndConfirmTare();

      clock = clock.add(const Duration(seconds: 1));
      scale.emitWeight(30, flow: 0, at: clock);
      await settle();
      expect(m.requested.where((s) => s == MachineState.idle).length, 1);

      m.emit(_snap(MachineState.idle, substate: MachineSubstate.idle));
      await settle();
      expect(sequencer.isArmed, isFalse);

      m.emit(_snap(MachineState.hotWater));
      await settle();
      expect(sequencer.isArmed, isTrue);
      expect(scale.tareCount, 2, reason: 'a fresh tare per dispense');
      scale.emitWeight(0, flow: 0, at: clock);
      await settle();
      clock = clock.add(const Duration(seconds: 1));
      scale.emitWeight(30, flow: 0, at: clock);
      await settle();
      expect(m.requested.where((s) => s == MachineState.idle).length, 2);
      m.dispose();
    });
  });

  group('disarming', () {
    test('disarms when the machine leaves hotWater', () async {
      await build();
      final m = _TestMachine();
      de1.emitMachine(m);
      await settle();
      m.emit(_snap(MachineState.hotWater));
      await settle();
      expect(sequencer.isArmed, isTrue);

      m.emit(_snap(MachineState.idle, substate: MachineSubstate.idle));
      await settle();
      expect(sequencer.isArmed, isFalse);
      m.dispose();
    });

    test('disarms when the machine disconnects', () async {
      await build();
      final m = _TestMachine();
      de1.emitMachine(m);
      await settle();
      m.emit(_snap(MachineState.hotWater));
      await settle();
      expect(sequencer.isArmed, isTrue);

      de1.emitMachine(null);
      await settle();
      expect(sequencer.isArmed, isFalse);
    });
  });
}
