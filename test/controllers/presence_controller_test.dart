import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/firmware_update_state.dart';
import 'package:reaprime/src/models/device/de1_rawmessage.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/subjects.dart';

import '../helpers/mock_settings_service.dart';

class _FakeDiscoveryService implements DeviceDiscoveryService {
  @override
  Stream<List<Device>> get devices => const Stream.empty();
  @override
  Future<void> initialize() async {}
  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {}
  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async => null;
}

class _TestDe1 implements De1Interface {
  final BehaviorSubject<MachineSnapshot> _snapshotSubject =
      BehaviorSubject.seeded(
        MachineSnapshot(
          timestamp: DateTime(2026, 1, 15, 8, 0),
          state: const MachineStateSnapshot(
            state: MachineState.idle,
            substate: MachineSubstate.idle,
          ),
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
        ),
      );

  int sendUserPresentCount = 0;
  final List<MachineState> requestedStates = [];

  void emitState(MachineState state) {
    final current = _snapshotSubject.value;
    _snapshotSubject.add(
      current.copyWith(
        state: MachineStateSnapshot(
          state: state,
          substate: MachineSubstate.idle,
        ),
      ),
    );
  }

  @override
  Stream<MachineSnapshot> get currentSnapshot => _snapshotSubject.stream;

  @override
  Future<void> sendUserPresent() async {
    sendUserPresentCount++;
  }

  @override
  Future<void> requestState(MachineState newState) async {
    requestedStates.add(newState);
    emitState(newState);
  }

  @override
  String get deviceId => 'test-de1';
  @override
  String get name => 'TestDe1';
  @override
  DeviceType get type => DeviceType.machine;

  @override
  DeviceImplementation get implementation => deviceImplementation;

  @override
  TransportType get transportType => TransportType.unknown;
  @override
  Future<void> onConnect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<ConnectionState> get connectionState =>
      BehaviorSubject.seeded(ConnectionState.connected).stream;
  @override
  Stream<bool> get ready => Stream.value(true);

  String fwBuild = '1';
  DeviceImplementation deviceImplementation = DeviceImplementation.unifiedDe1;

  @override
  MachineInfo get machineInfo => MachineInfo(
    version: fwBuild,
    model: '1',
    serialNumber: '1',
    groupHeadControllerPresent: false,
    extra: {},
  );
  @override
  Stream<De1ShotSettings> get shotSettings => const Stream.empty();
  @override
  Future<void> updateShotSettings(De1ShotSettings newSettings) async {}
  @override
  Stream<De1WaterLevels> get waterLevels => const Stream.empty();
  @override
  Future<void> setRefillLevel(int newRefillLevel) async {}
  @override
  Future<void> setProfile(Profile profile) async {}
  @override
  Future<void> setFanThreshhold(int temp) async {}
  @override
  Future<int> getFanThreshhold() async => 0;
  @override
  Future<int> getTankTempThreshold() async => 0;
  @override
  Future<void> setTankTempThreshold(int temp) async {}
  @override
  Future<void> setSteamFlow(double newFlow) async {}
  @override
  Future<double> getSteamFlow() async => 0;
  @override
  Future<void> setHotWaterFlow(double newFlow) async {}
  @override
  Future<double> getHotWaterFlow() async => 0;
  @override
  Future<void> setFlushFlow(double newFlow) async {}
  @override
  Future<double> getFlushFlow() async => 0;
  @override
  Future<void> setFlushTimeout(double newTimeout) async {}
  @override
  Future<double> getFlushTimeout() async => 0;
  @override
  Future<double> getFlushTemperature() async => 0;
  @override
  Future<void> setFlushTemperature(double newTemp) async {}
  @override
  Future<double> getFlowEstimation() async => 1.0;
  @override
  double? get cachedFlowEstimation => 1.0;
  @override
  Future<void> setFlowEstimation(double multiplier) async {}
  @override
  Future<De1Calibration> readCalibration(
    De1CalibrationTarget target, {
    De1CalibrationSource source = De1CalibrationSource.current,
  }) async =>
      De1Calibration(target: target, de1ReportedValue: 1.0, measuredValue: 1.0);
  @override
  Future<void> writeCalibration(De1Calibration calibration) async {}
  @override
  Future<bool> getUsbChargerMode() async => false;
  @override
  Future<void> setUsbChargerMode(bool t) async {}
  @override
  Future<void> setSteamPurgeMode(int mode) async {}
  @override
  Future<int> getSteamPurgeMode() async => 0;
  @override
  Future<void> enableUserPresenceFeature() async {}
  @override
  Stream<De1RawMessage> get rawOutStream => const Stream.empty();
  @override
  void sendRawMessage(De1RawMessage message) {}
  @override
  Future<double> getHeaterPhase1Flow() async => 0;
  @override
  Future<void> setHeaterPhase1Flow(double val) async {}
  @override
  Future<double> getHeaterPhase2Flow() async => 0;
  @override
  Future<void> setHeaterPhase2Flow(double val) async {}
  @override
  Future<double> getHeaterPhase2Timeout() async => 0;
  @override
  Future<void> setHeaterPhase2Timeout(double val) async {}
  @override
  Future<double> getHeaterIdleTemp() async => 0;
  @override
  Future<void> setHeaterIdleTemp(double val) async {}
  @override
  FirmwareUpdateState get firmwareUpdateState => FirmwareUpdateState.idle;
  @override
  Future<void> updateFirmware(
    Uint8List fwImage, {
    required void Function(double progress) onProgress,
  }) async {}
  @override
  Future<void> cancelFirmwareUpload() async {}
  @override
  Future<De1HeaterVoltage> getHeaterVoltage() async => .v110;
  @override
  Future<De1RefillKitSettings> getRefillKitSettings() async => .auto;
  @override
  Future<void> setHeaterVoltage(De1HeaterVoltage voltage) async {}
  @override
  Future<void> setRefillKitSettings(De1RefillKitSettings settings) async {}

  @override
  Future<void> dispose() async {}
}

class _TestDe1Controller extends De1Controller {
  final BehaviorSubject<De1Interface?> _de1Subject = BehaviorSubject.seeded(
    null,
  );

  _TestDe1Controller({required super.controller});

  @override
  Stream<De1Interface?> get de1 => _de1Subject.stream;

  void setDe1(De1Interface? de1) {
    _de1Subject.add(de1);
  }
}

void main() {
  late _TestDe1Controller de1Controller;
  late SettingsController settingsController;
  late _TestDe1 testDe1;

  setUp(() async {
    final discoveryService = _FakeDiscoveryService();
    final deviceController = DeviceController([discoveryService]);
    de1Controller = _TestDe1Controller(controller: deviceController);

    final mockSettings = MockSettingsService();
    settingsController = SettingsController(mockSettings);
    await settingsController.loadSettings();

    testDe1 = _TestDe1();
  });

  group('heartbeat() throttling', () {
    test('two calls within 5s = only 1 sendUserPresent() call', () {
      fakeAsync((async) {
        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);

        async.flushMicrotasks();

        controller.heartbeat();
        async.elapse(const Duration(seconds: 3));
        controller.heartbeat();
        async.elapse(const Duration(seconds: 5));

        expect(testDe1.sendUserPresentCount, 1);

        controller.dispose();
      });
    });

    test('second call after 5s is allowed, total = 2 sendUserPresent()', () {
      fakeAsync((async) {
        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.heartbeat();
        async.elapse(const Duration(seconds: 31));
        controller.heartbeat();
        async.elapse(const Duration(seconds: 1));

        expect(testDe1.sendUserPresentCount, 2);

        controller.dispose();
      });
    });
  });

  group('sleep timeout', () {
    test(
      'heartbeat resets sleep timer - no sleep if heartbeat before timeout',
      () {
        fakeAsync((async) {
          settingsController.setSleepTimeoutMinutes(5);
          async.flushMicrotasks();

          final controller = PresenceController(
            de1Controller: de1Controller,
            settingsController: settingsController,
            clock: () => clock.now(),
          );
          controller.initialize();
          de1Controller.setDe1(testDe1);
          async.flushMicrotasks();

          controller.heartbeat();
          async.flushMicrotasks();

          async.elapse(const Duration(minutes: 4, seconds: 50));
          expect(testDe1.requestedStates, isEmpty);

          controller.heartbeat();
          async.flushMicrotasks();

          async.elapse(const Duration(seconds: 20));
          expect(
            testDe1.requestedStates.contains(MachineState.sleeping),
            isFalse,
            reason: 'heartbeat should have reset the timer',
          );

          controller.dispose();
        });
      },
    );

    test(
      'no heartbeat for configured minutes sends requestState(sleeping)',
      () {
        fakeAsync((async) {
          settingsController.setSleepTimeoutMinutes(5);
          async.flushMicrotasks();

          final controller = PresenceController(
            de1Controller: de1Controller,
            settingsController: settingsController,
            clock: () => clock.now(),
          );
          controller.initialize();
          de1Controller.setDe1(testDe1);
          async.flushMicrotasks();

          controller.heartbeat();
          async.flushMicrotasks();

          async.elapse(const Duration(minutes: 5, seconds: 1));

          expect(testDe1.requestedStates, contains(MachineState.sleeping));

          controller.dispose();
        });
      },
    );

    test('timeout = 0 means disabled — no sleep even after long time', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(0);
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.heartbeat();
        async.flushMicrotasks();

        async.elapse(const Duration(hours: 2));

        expect(testDe1.requestedStates, isEmpty);

        controller.dispose();
      });
    });

    test('sleep timeout paused during espresso — timer restarts instead', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.heartbeat();
        async.flushMicrotasks();

        testDe1.emitState(MachineState.espresso);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(
          testDe1.requestedStates.where((s) => s == MachineState.sleeping),
          isEmpty,
          reason: 'Machine in espresso should not be put to sleep',
        );

        testDe1.emitState(MachineState.idle);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(testDe1.requestedStates, contains(MachineState.sleeping));

        controller.dispose();
      });
    });

    test(
      'sleep countdown restarts when a shot ends, not from the last heartbeat',
      () {
        fakeAsync((async) {
          settingsController.setSleepTimeoutMinutes(5);
          async.flushMicrotasks();

          final controller = PresenceController(
            de1Controller: de1Controller,
            settingsController: settingsController,
            clock: () => clock.now(),
          );
          controller.initialize();
          de1Controller.setDe1(testDe1);
          async.flushMicrotasks();

          controller.heartbeat();
          async.flushMicrotasks();

          async.elapse(const Duration(minutes: 1));
          testDe1.emitState(MachineState.espresso);
          async.flushMicrotasks();
          async.elapse(const Duration(minutes: 1));
          testDe1.emitState(MachineState.idle);
          async.flushMicrotasks();

          async.elapse(const Duration(minutes: 3, seconds: 30));
          expect(
            testDe1.requestedStates.where((s) => s == MachineState.sleeping),
            isEmpty,
            reason: 'Shot end should have restarted the sleep countdown',
          );

          async.elapse(const Duration(minutes: 2));
          expect(testDe1.requestedStates, contains(MachineState.sleeping));

          controller.dispose();
        });
      },
    );

    test('needsWater on FW >= 1357 sleeps after timeout', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        testDe1.fwBuild = '1357';
        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.heartbeat();
        async.flushMicrotasks();

        testDe1.emitState(MachineState.needsWater);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(
          testDe1.requestedStates,
          contains(MachineState.sleeping),
          reason: 'FW >= 1357 honors sleep while in refill',
        );

        controller.dispose();
      });
    });

    test('needsWater on FW < 1357 does NOT sleep after timeout', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.heartbeat();
        async.flushMicrotasks();

        testDe1.emitState(MachineState.needsWater);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(
          testDe1.requestedStates.where((s) => s == MachineState.sleeping),
          isEmpty,
          reason:
              'FW < 1357 latches the request; must not send sleep from needsWater',
        );

        controller.heartbeat();
        async.flushMicrotasks();
        testDe1.emitState(MachineState.idle);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 5, seconds: 1));
        expect(testDe1.requestedStates, contains(MachineState.sleeping));

        controller.dispose();
      });
    });

    test('needsWater on Bengle does NOT sleep even on FW >= 1357', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        testDe1.fwBuild = '1357';
        testDe1.deviceImplementation = DeviceImplementation.bengle;
        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.heartbeat();
        async.flushMicrotasks();

        testDe1.emitState(MachineState.needsWater);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(
          testDe1.requestedStates.where((s) => s == MachineState.sleeping),
          isEmpty,
          reason: 'sleep-from-needsWater is DE1-only',
        );

        controller.dispose();
      });
    });
  });

  group('scheduled wake', () {
    test('wakes sleeping machine at matching schedule time', () {
      fakeAsync((async) {
        final schedule = WakeSchedule(
          id: 'test-1',
          hour: 7,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
        );
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([schedule]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 6, 59),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        controller.clockOverride = () => DateTime(2026, 1, 15, 7, 0);
        async.elapse(const Duration(seconds: 31));

        expect(testDe1.requestedStates, contains(MachineState.schedIdle));

        controller.dispose();
      });
    });

    test('schedule does not wake non-sleeping machine', () {
      fakeAsync((async) {
        final schedule = WakeSchedule(
          id: 'test-2',
          hour: 7,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
        );
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([schedule]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 7, 0),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.idle);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 61));

        expect(
          testDe1.requestedStates.where((s) => s == MachineState.schedIdle),
          isEmpty,
          reason:
              'Schedule should not wake a machine that is not in sleeping state',
        );

        controller.dispose();
      });
    });
  });

  group('disconnected DE1', () {
    test('heartbeat returns -1 when no DE1 connected', () {
      fakeAsync((async) {
        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        async.flushMicrotasks();

        final result = controller.heartbeat();
        expect(result, -1);

        controller.dispose();
      });
    });

    test('heartbeat returns -1 when presence not enabled', () {
      fakeAsync((async) {
        settingsController.setUserPresenceEnabled(false);
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        final result = controller.heartbeat();
        expect(result, -1);

        controller.dispose();
      });
    });
  });

  group('settings change', () {
    test('changing sleepTimeoutMinutes resets the active timer', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.heartbeat();
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 4));
        expect(testDe1.requestedStates, isEmpty);

        settingsController.setSleepTimeoutMinutes(10);
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 6));
        expect(
          testDe1.requestedStates.contains(MachineState.sleeping),
          isFalse,
          reason:
              'Timer should have been reset to 10 min when settings changed',
        );

        async.elapse(const Duration(minutes: 4, seconds: 1));
        expect(testDe1.requestedStates, contains(MachineState.sleeping));

        controller.dispose();
      });
    });
  });

  group('keep-awake window', () {
    test('schedule with keepAwakeFor suppresses sleep timeout', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        final schedule = WakeSchedule(
          id: 'keep-awake-1',
          hour: 7,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
          keepAwakeFor: 60,
        );
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([schedule]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 6, 59),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        controller.clockOverride = () => DateTime(2026, 1, 15, 7, 0);
        async.elapse(const Duration(seconds: 31));

        expect(testDe1.requestedStates, contains(MachineState.schedIdle));

        controller.heartbeat();
        async.flushMicrotasks();

        controller.clockOverride = () => DateTime(2026, 1, 15, 7, 6);
        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(
          testDe1.requestedStates.where((s) => s == MachineState.sleeping),
          isEmpty,
          reason: 'Keep-awake window should suppress sleep timeout',
        );

        controller.dispose();
      });
    });

    test('sleep timeout fires after keep-awake window expires', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        final schedule = WakeSchedule(
          id: 'keep-awake-2',
          hour: 7,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
          keepAwakeFor: 10,
        );
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([schedule]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 6, 59),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        controller.clockOverride = () => DateTime(2026, 1, 15, 7, 0);
        async.elapse(const Duration(seconds: 31));
        expect(testDe1.requestedStates, contains(MachineState.schedIdle));

        controller.heartbeat();
        async.flushMicrotasks();

        controller.clockOverride = () => DateTime(2026, 1, 15, 7, 16);
        async.elapse(const Duration(minutes: 15, seconds: 1));

        expect(testDe1.requestedStates, contains(MachineState.sleeping));

        controller.dispose();
      });
    });

    test('manual sleep during keep-awake clears the window', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        final schedule = WakeSchedule(
          id: 'keep-awake-3',
          hour: 7,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
          keepAwakeFor: 60,
        );
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([schedule]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 6, 59),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        controller.clockOverride = () => DateTime(2026, 1, 15, 7, 0);
        async.elapse(const Duration(seconds: 31));

        expect(controller.keepAwakeUntil, isNotNull);

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        expect(controller.keepAwakeUntil, isNull);

        controller.dispose();
      });
    });

    test('schedule without keepAwakeFor does not set keep-awake', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        final schedule = WakeSchedule(
          id: 'no-keep-awake',
          hour: 7,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
        );
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([schedule]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 6, 59),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        controller.clockOverride = () => DateTime(2026, 1, 15, 7, 0);
        async.elapse(const Duration(seconds: 31));

        expect(controller.keepAwakeUntil, isNull);

        controller.dispose();
      });
    });

    test('later schedule extends keep-awake if expiry is further', () {
      fakeAsync((async) {
        settingsController.setSleepTimeoutMinutes(5);
        async.flushMicrotasks();

        final schedules = [
          WakeSchedule(
            id: 'short',
            hour: 7,
            minute: 0,
            daysOfWeek: {},
            enabled: true,
            keepAwakeFor: 30,
          ),
          WakeSchedule(
            id: 'long',
            hour: 7,
            minute: 1,
            daysOfWeek: {},
            enabled: true,
            keepAwakeFor: 120,
          ),
        ];
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList(schedules),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 6, 59),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        controller.clockOverride = () => DateTime(2026, 1, 15, 7, 0);
        async.elapse(const Duration(seconds: 31));

        final firstExpiry = controller.keepAwakeUntil;
        expect(firstExpiry, isNotNull);

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        controller.clockOverride = () => DateTime(2026, 1, 15, 7, 1);
        async.elapse(const Duration(seconds: 31));

        final secondExpiry = controller.keepAwakeUntil;
        expect(secondExpiry, isNotNull);
        expect(secondExpiry!.isAfter(firstExpiry!), isTrue);

        controller.dispose();
      });
    });

    test(
      'already-awake machine keeps the occurrence after its start minute',
      () {
        fakeAsync((async) {
          settingsController.setSleepTimeoutMinutes(30);
          settingsController.setWakeSchedules(
            WakeSchedule.serializeList([
              const WakeSchedule(
                id: 'already-awake',
                hour: 5,
                minute: 30,
                daysOfWeek: {1, 2, 3, 4, 5},
                enabled: true,
                keepAwakeFor: 90,
              ),
            ]),
          );
          async.flushMicrotasks();

          final controller = PresenceController(
            de1Controller: de1Controller,
            settingsController: settingsController,
            clock: () => DateTime(2026, 1, 15, 6),
          );
          controller.initialize();
          de1Controller.setDe1(testDe1);
          async.flushMicrotasks();

          controller.heartbeat();
          async.elapse(const Duration(minutes: 30, seconds: 1));

          expect(controller.keepAwakeUntil, DateTime(2026, 1, 15, 7));
          expect(
            testDe1.requestedStates,
            isNot(contains(MachineState.sleeping)),
          );

          controller.clockOverride = () => DateTime(2026, 1, 15, 7, 1);
          async.elapse(const Duration(minutes: 30, seconds: 1));

          expect(testDe1.requestedStates, contains(MachineState.sleeping));
          controller.dispose();
        });
      },
    );

    test('reconnecting during an occurrence preserves keep-awake', () {
      fakeAsync((async) {
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([
            const WakeSchedule(
              id: 'reconnect',
              hour: 7,
              minute: 0,
              daysOfWeek: {},
              enabled: true,
              keepAwakeFor: 60,
            ),
          ]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 7, 30),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();
        de1Controller.setDe1(null);
        async.flushMicrotasks();

        expect(controller.keepAwakeUntil, isNull);

        final reconnected = _TestDe1();
        de1Controller.setDe1(reconnected);
        async.flushMicrotasks();

        expect(controller.keepAwakeUntil, DateTime(2026, 1, 15, 8));
        controller.dispose();
      });
    });

    test('new controller derives an occurrence already in progress', () {
      fakeAsync((async) {
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([
            const WakeSchedule(
              id: 'restart',
              hour: 7,
              minute: 0,
              daysOfWeek: {},
              enabled: true,
              keepAwakeFor: 60,
            ),
          ]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 7, 30),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        expect(controller.keepAwakeUntil, DateTime(2026, 1, 15, 8));
        controller.dispose();
      });
    });

    test('waking again does not restore a manually cancelled occurrence', () {
      fakeAsync((async) {
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([
            const WakeSchedule(
              id: 'manual-cancel',
              hour: 7,
              minute: 0,
              daysOfWeek: {},
              enabled: true,
              keepAwakeFor: 60,
            ),
          ]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 7, 30),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();
        expect(controller.keepAwakeUntil, isNull);

        testDe1.emitState(MachineState.idle);
        async.flushMicrotasks();
        expect(controller.keepAwakeUntil, isNull);

        controller.dispose();
      });
    });

    test('changing a schedule does not restore a cancelled occurrence', () {
      fakeAsync((async) {
        const schedule = WakeSchedule(
          id: 'changed',
          hour: 7,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
          keepAwakeFor: 60,
        );
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([schedule]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 7, 30),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();
        expect(controller.keepAwakeUntil, isNull);

        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([schedule.copyWith(keepAwakeFor: 120)]),
        );
        async.flushMicrotasks();

        testDe1.emitState(MachineState.idle);
        async.flushMicrotasks();
        expect(controller.keepAwakeUntil, isNull);
        controller.dispose();
      });
    });

    test('a later concrete occurrence works after cancellation', () {
      fakeAsync((async) {
        const schedule = WakeSchedule(
          id: 'recurring',
          hour: 7,
          minute: 0,
          daysOfWeek: {},
          enabled: true,
          keepAwakeFor: 60,
        );
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([schedule]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 7, 30),
        );
        controller.initialize();
        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();
        expect(controller.keepAwakeUntil, isNull);

        controller.clockOverride = () => DateTime(2026, 1, 16, 7, 30);
        testDe1.emitState(MachineState.idle);
        async.flushMicrotasks();

        expect(controller.keepAwakeUntil, DateTime(2026, 1, 16, 8));
        controller.dispose();
      });
    });

    test('keepAwakeUntil is null without a connected machine', () {
      fakeAsync((async) {
        settingsController.setWakeSchedules(
          WakeSchedule.serializeList([
            const WakeSchedule(
              id: 'disconnected',
              hour: 7,
              minute: 0,
              daysOfWeek: {},
              enabled: true,
              keepAwakeFor: 60,
            ),
          ]),
        );
        async.flushMicrotasks();

        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => DateTime(2026, 1, 15, 7, 30),
        );
        controller.initialize();
        async.flushMicrotasks();

        expect(controller.keepAwakeUntil, isNull);
        controller.dispose();
      });
    });
  });
}
