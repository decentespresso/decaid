import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/charging_logic.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
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
import 'package:reaprime/src/settings/charging_mode.dart';
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
  Future<void> sendUserPresent() async {}

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
  DeviceImplementation get implementation => DeviceImplementation.unifiedDe1;

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
  @override
  MachineInfo get machineInfo => MachineInfo(
    version: '1',
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

class _TestBatteryController {
  final BehaviorSubject<ChargingState> _stateSubject =
      BehaviorSubject<ChargingState>();

  Stream<ChargingState> get chargingState => _stateSubject.stream;
  ChargingState? get currentChargingState => _stateSubject.valueOrNull;

  void emitBattery(int percent) {
    _stateSubject.add(
      ChargingState(
        mode: ChargingMode.balanced,
        nightModeEnabled: false,
        currentPhase: NightPhase.inactive,
        batteryPercent: percent,
        usbChargerOn: false,
        isEmergency: percent <= 15,
      ),
    );
  }

  void dispose() {
    _stateSubject.close();
  }
}

DisplayController _createController(
  _TestDe1Controller de1Controller, {
  required SettingsController settingsController,
  _TestBatteryController? batteryController,
  DisplayPlatformSupport? platformSupport,
}) {
  return DisplayController(
    de1Controller: de1Controller,
    settingsController: settingsController,
    batteryStateStream: batteryController?.chargingState,
    setBrightness: (_) async {},
    resetBrightness: () async {},
    enableWakeLock: () async {},
    disableWakeLock: () async {},
    platformSupport:
        platformSupport ??
        const DisplayPlatformSupport(brightness: true, wakeLock: true),
  );
}

void main() {
  late _TestDe1Controller de1Controller;
  late _TestDe1 testDe1;
  late SettingsController settingsCtrl;

  setUp(() async {
    final discoveryService = _FakeDiscoveryService();
    final deviceController = DeviceController([discoveryService]);
    de1Controller = _TestDe1Controller(controller: deviceController);
    testDe1 = _TestDe1();

    final mockSettings = MockSettingsService();
    settingsCtrl = SettingsController(mockSettings);
    await settingsCtrl.loadSettings();
    await settingsCtrl.setKeepAwake(false);
  });

  group('initial state', () {
    test('starts with wake-lock disabled, brightness 100, no override', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        final state = controller.currentState;
        expect(state.wakeLockEnabled, isFalse);
        expect(state.brightness, 100);
        expect(state.requestedBrightness, 100);
        expect(state.lowBatteryBrightnessActive, isFalse);
        expect(state.wakeLockOverride, isFalse);

        controller.dispose();
      });
    });

    test('platformSupported reports correct values', () {
      fakeAsync((async) {
        final controller = DisplayController(
          de1Controller: de1Controller,
          settingsController: settingsCtrl,
          setBrightness: (_) async {},
          resetBrightness: () async {},
          enableWakeLock: () async {},
          disableWakeLock: () async {},
        );
        controller.initialize();
        async.flushMicrotasks();

        final state = controller.currentState;
        expect(state.platformSupported.wakeLock, isTrue);
        final expectedBrightness =
            Platform.isAndroid ||
            Platform.isIOS ||
            Platform.isMacOS ||
            Platform.isWindows;
        expect(state.platformSupported.brightness, expectedBrightness);

        controller.dispose();
      });
    });
  });

  group('auto wake-lock', () {
    test('enables wake-lock when DE1 connects', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        expect(controller.currentState.wakeLockEnabled, isTrue);

        controller.dispose();
      });
    });

    test('disables wake-lock when DE1 disconnects', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isTrue);

        de1Controller.setDe1(null);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isFalse);

        controller.dispose();
      });
    });

    test('disables wake-lock when machine enters sleep', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isTrue);

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isFalse);

        controller.dispose();
      });
    });

    test('re-enables wake-lock when machine wakes from sleep', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isFalse);

        testDe1.emitState(MachineState.idle);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isTrue);

        controller.dispose();
      });
    });
  });

  group('wake-lock override', () {
    test('requestWakeLock enables wake-lock and sets override flag', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.requestWakeLock();
        async.flushMicrotasks();

        expect(controller.currentState.wakeLockOverride, isTrue);
        expect(controller.currentState.wakeLockEnabled, isTrue);

        controller.dispose();
      });
    });

    test(
      'releaseWakeLock clears override and disables wake-lock when disconnected',
      () {
        fakeAsync((async) {
          final controller = _createController(
            de1Controller,
            settingsController: settingsCtrl,
          );
          controller.initialize();
          async.flushMicrotasks();

          controller.requestWakeLock();
          async.flushMicrotasks();
          expect(controller.currentState.wakeLockOverride, isTrue);
          expect(controller.currentState.wakeLockEnabled, isTrue);

          controller.releaseWakeLock();
          async.flushMicrotasks();
          expect(controller.currentState.wakeLockOverride, isFalse);
          expect(controller.currentState.wakeLockEnabled, isFalse);

          controller.dispose();
        });
      },
    );

    test('override keeps wake-lock enabled even when machine sleeps', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.requestWakeLock();
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        expect(controller.currentState.wakeLockEnabled, isTrue);
        expect(controller.currentState.wakeLockOverride, isTrue);

        controller.dispose();
      });
    });

    test('releasing override while machine sleeping disables wake-lock', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.requestWakeLock();
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        controller.releaseWakeLock();
        async.flushMicrotasks();

        expect(controller.currentState.wakeLockOverride, isFalse);
        expect(controller.currentState.wakeLockEnabled, isFalse);

        controller.dispose();
      });
    });
  });

  group('keepAwake setting', () {
    test('keeps wake-lock enabled while machine sleeps', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        settingsCtrl.setKeepAwake(true);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isTrue);

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();
        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isTrue);

        controller.dispose();
      });
    });

    test('keeps wake-lock enabled while disconnected', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isTrue);

        settingsCtrl.setKeepAwake(true);
        async.flushMicrotasks();
        de1Controller.setDe1(null);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isTrue);

        controller.dispose();
      });
    });

    test(
      'initializing while disconnected with keepAwake already set keeps wake-lock on',
      () {
        fakeAsync((async) {
          settingsCtrl.setKeepAwake(true);
          async.flushMicrotasks();

          final controller = _createController(
            de1Controller,
            settingsController: settingsCtrl,
          );
          controller.initialize();
          async.flushMicrotasks();

          expect(controller.currentState.wakeLockEnabled, isTrue);

          controller.dispose();
        });
      },
    );

    test('disabling keepAwake while sleeping releases wake-lock', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        settingsCtrl.setKeepAwake(true);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isTrue);

        settingsCtrl.setKeepAwake(false);
        async.flushMicrotasks();
        expect(controller.currentState.wakeLockEnabled, isFalse);

        controller.dispose();
      });
    });
  });

  group('brightness', () {
    test('initial brightness is 100', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 100);
        expect(controller.currentState.requestedBrightness, 100);

        controller.dispose();
      });
    });

    test('setBrightness(50) sets brightness to 50', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(50);
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 50);
        expect(controller.currentState.requestedBrightness, 50);

        controller.dispose();
      });
    });

    test('clamps values above 100 to 100', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(150);
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 100);
        expect(controller.currentState.requestedBrightness, 100);

        controller.dispose();
      });
    });

    test('clamps values below 0 to 0', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(-10);
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 0);
        expect(controller.currentState.requestedBrightness, 0);

        controller.dispose();
      });
    });

    test('setBrightness(100) calls resetBrightness', () {
      fakeAsync((async) {
        var resetCalled = false;
        var setBrightnessCalled = false;

        final controller = DisplayController(
          de1Controller: de1Controller,
          settingsController: settingsCtrl,
          setBrightness: (_) async {
            setBrightnessCalled = true;
          },
          resetBrightness: () async {
            resetCalled = true;
          },
          enableWakeLock: () async {},
          disableWakeLock: () async {},
          platformSupport: const DisplayPlatformSupport(
            brightness: true,
            wakeLock: true,
          ),
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(50);
        async.flushMicrotasks();
        resetCalled = false;
        setBrightnessCalled = false;

        controller.setBrightness(100);
        async.flushMicrotasks();

        expect(resetCalled, isTrue);
        expect(setBrightnessCalled, isFalse);

        controller.dispose();
      });
    });

    test('saves brightness before sleep and restores on wake', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.setBrightness(60);
        async.flushMicrotasks();
        expect(controller.currentState.brightness, 60);

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.idle);
        async.flushMicrotasks();
        expect(controller.currentState.brightness, 60);

        controller.dispose();
      });
    });

    test(
      'restores brightness on wake even when the sleep->idle edge is missed',
      () {
        fakeAsync((async) {
          final controller = _createController(
            de1Controller,
            settingsController: settingsCtrl,
          );
          controller.initialize();
          async.flushMicrotasks();

          de1Controller.setDe1(testDe1);
          async.flushMicrotasks();

          controller.setBrightness(100);
          testDe1.emitState(MachineState.sleeping);
          async.flushMicrotasks();
          controller.setBrightness(0);
          async.flushMicrotasks();
          expect(controller.currentState.brightness, 0);

          final reconnected = _TestDe1();
          de1Controller.setDe1(reconnected);
          async.flushMicrotasks();

          expect(controller.currentState.brightness, 100);

          controller.dispose();
        });
      },
    );

    test(
      'restores brightness when a dim-0 lands after the machine is already awake',
      () {
        fakeAsync((async) {
          final controller = _createController(
            de1Controller,
            settingsController: settingsCtrl,
          );
          controller.initialize();
          async.flushMicrotasks();

          de1Controller.setDe1(testDe1);
          async.flushMicrotasks();

          controller.setBrightness(100);
          async.flushMicrotasks();

          testDe1.emitState(MachineState.sleeping);
          async.flushMicrotasks();
          testDe1.emitState(MachineState.idle);
          async.flushMicrotasks();
          expect(controller.currentState.brightness, 100);

          controller.setBrightness(0);
          async.flushMicrotasks();
          expect(controller.currentState.brightness, 0);

          testDe1.emitState(MachineState.idle);
          async.flushMicrotasks();
          expect(controller.currentState.brightness, 100);

          controller.dispose();
        });
      },
    );

    test('onAppResumed restores brightness when awake and still dimmed', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.setBrightness(0);
        async.flushMicrotasks();
        expect(controller.currentState.brightness, 0);

        controller.onAppResumed();
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 100);

        controller.dispose();
      });
    });

    test(
      'onAppResumed re-applies brightness so an OS write that did not stick recovers',
      () {
        fakeAsync((async) {
          var resetCount = 0;
          final controller = DisplayController(
            de1Controller: de1Controller,
            settingsController: settingsCtrl,
            setBrightness: (_) async {},
            resetBrightness: () async {
              resetCount++;
            },
            enableWakeLock: () async {},
            disableWakeLock: () async {},
            platformSupport: const DisplayPlatformSupport(
              brightness: true,
              wakeLock: true,
            ),
          );
          controller.initialize();
          async.flushMicrotasks();

          de1Controller.setDe1(testDe1);
          async.flushMicrotasks();

          controller.setBrightness(100);
          async.flushMicrotasks();
          final before = resetCount;

          controller.onAppResumed();
          async.flushMicrotasks();

          expect(resetCount, greaterThan(before));

          controller.dispose();
        });
      },
    );
  });

  group('battery brightness cap', () {
    test('caps brightness when battery low and setting enabled', () {
      fakeAsync((async) {
        final batteryCtrl = _TestBatteryController();
        settingsCtrl.setLowBatteryBrightnessLimit(true);
        async.flushMicrotasks();

        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
          batteryController: batteryCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(80);
        async.flushMicrotasks();
        expect(controller.currentState.brightness, 80);

        batteryCtrl.emitBattery(20);
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 20);
        expect(controller.currentState.requestedBrightness, 80);
        expect(controller.currentState.lowBatteryBrightnessActive, isTrue);

        controller.dispose();
        batteryCtrl.dispose();
      });
    });

    test('does not cap when setting is off', () {
      fakeAsync((async) {
        final batteryCtrl = _TestBatteryController();

        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
          batteryController: batteryCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(80);
        async.flushMicrotasks();

        batteryCtrl.emitBattery(20);
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 80);
        expect(controller.currentState.lowBatteryBrightnessActive, isFalse);

        controller.dispose();
        batteryCtrl.dispose();
      });
    });

    test('allows values already below cap', () {
      fakeAsync((async) {
        final batteryCtrl = _TestBatteryController();
        settingsCtrl.setLowBatteryBrightnessLimit(true);
        async.flushMicrotasks();

        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
          batteryController: batteryCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(10);
        async.flushMicrotasks();

        batteryCtrl.emitBattery(20);
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 10);
        expect(controller.currentState.requestedBrightness, 10);
        expect(controller.currentState.lowBatteryBrightnessActive, isFalse);

        controller.dispose();
        batteryCtrl.dispose();
      });
    });

    test('restores brightness on battery recovery', () {
      fakeAsync((async) {
        final batteryCtrl = _TestBatteryController();
        settingsCtrl.setLowBatteryBrightnessLimit(true);
        async.flushMicrotasks();

        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
          batteryController: batteryCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(80);
        async.flushMicrotasks();

        batteryCtrl.emitBattery(20);
        async.flushMicrotasks();
        expect(controller.currentState.brightness, 20);

        batteryCtrl.emitBattery(50);
        async.flushMicrotasks();
        expect(controller.currentState.brightness, 80);
        expect(controller.currentState.lowBatteryBrightnessActive, isFalse);

        controller.dispose();
        batteryCtrl.dispose();
      });
    });

    test('toggling setting off restores brightness immediately', () {
      fakeAsync((async) {
        final batteryCtrl = _TestBatteryController();
        settingsCtrl.setLowBatteryBrightnessLimit(true);
        async.flushMicrotasks();

        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
          batteryController: batteryCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(80);
        async.flushMicrotasks();

        batteryCtrl.emitBattery(20);
        async.flushMicrotasks();
        expect(controller.currentState.brightness, 20);

        settingsCtrl.setLowBatteryBrightnessLimit(false);
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 80);
        expect(controller.currentState.lowBatteryBrightnessActive, isFalse);

        controller.dispose();
        batteryCtrl.dispose();
      });
    });

    test('toggling setting on applies cap immediately when battery low', () {
      fakeAsync((async) {
        final batteryCtrl = _TestBatteryController();

        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
          batteryController: batteryCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(80);
        async.flushMicrotasks();

        batteryCtrl.emitBattery(20);
        async.flushMicrotasks();
        expect(controller.currentState.brightness, 80);

        settingsCtrl.setLowBatteryBrightnessLimit(true);
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 20);
        expect(controller.currentState.lowBatteryBrightnessActive, isTrue);

        controller.dispose();
        batteryCtrl.dispose();
      });
    });

    test('no cap without battery controller (desktop)', () {
      fakeAsync((async) {
        settingsCtrl.setLowBatteryBrightnessLimit(true);
        async.flushMicrotasks();

        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        controller.setBrightness(80);
        async.flushMicrotasks();

        expect(controller.currentState.brightness, 80);
        expect(controller.currentState.lowBatteryBrightnessActive, isFalse);

        controller.dispose();
      });
    });

    test('sleep/wake with battery cap preserves pre-sleep brightness', () {
      fakeAsync((async) {
        final batteryCtrl = _TestBatteryController();
        settingsCtrl.setLowBatteryBrightnessLimit(true);
        async.flushMicrotasks();

        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
          batteryController: batteryCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        controller.setBrightness(80);
        async.flushMicrotasks();
        batteryCtrl.emitBattery(20);
        async.flushMicrotasks();
        expect(controller.currentState.brightness, 20);
        expect(controller.currentState.requestedBrightness, 80);

        testDe1.emitState(MachineState.sleeping);
        async.flushMicrotasks();

        testDe1.emitState(MachineState.idle);
        async.flushMicrotasks();
        expect(controller.currentState.requestedBrightness, 80);
        expect(controller.currentState.brightness, 20);
        expect(controller.currentState.lowBatteryBrightnessActive, isTrue);

        controller.dispose();
        batteryCtrl.dispose();
      });
    });
  });

  group('state broadcasting', () {
    test('stream emits initial state', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        final emissions = <DisplayState>[];
        final sub = controller.state.listen(emissions.add);
        async.flushMicrotasks();

        expect(emissions, isNotEmpty);
        expect(emissions.first.wakeLockEnabled, isFalse);
        expect(emissions.first.brightness, 100);
        expect(emissions.first.wakeLockOverride, isFalse);

        sub.cancel();
        controller.dispose();
      });
    });

    test('stream emits on wake-lock override changes', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        final emissions = <DisplayState>[];
        final sub = controller.state.listen(emissions.add);
        async.flushMicrotasks();

        final initialCount = emissions.length;

        controller.requestWakeLock();
        async.flushMicrotasks();

        expect(emissions.length, greaterThan(initialCount));
        expect(emissions.last.wakeLockOverride, isTrue);
        expect(emissions.last.wakeLockEnabled, isTrue);

        controller.releaseWakeLock();
        async.flushMicrotasks();

        expect(emissions.last.wakeLockOverride, isFalse);

        sub.cancel();
        controller.dispose();
      });
    });

    test('stream emits on DE1 connect/disconnect', () {
      fakeAsync((async) {
        final controller = _createController(
          de1Controller,
          settingsController: settingsCtrl,
        );
        controller.initialize();
        async.flushMicrotasks();

        final emissions = <DisplayState>[];
        final sub = controller.state.listen(emissions.add);
        async.flushMicrotasks();

        final preConnectCount = emissions.length;

        de1Controller.setDe1(testDe1);
        async.flushMicrotasks();

        expect(emissions.length, greaterThan(preConnectCount));
        expect(emissions.last.wakeLockEnabled, isTrue);

        de1Controller.setDe1(null);
        async.flushMicrotasks();

        expect(emissions.last.wakeLockEnabled, isFalse);

        sub.cancel();
        controller.dispose();
      });
    });

    test('dispose closes state stream', () async {
      final controller = _createController(
        de1Controller,
        settingsController: settingsCtrl,
      );
      controller.initialize();

      final completer = Completer<void>();
      final sub = controller.state.listen(
        (_) {},
        onDone: () => completer.complete(),
      );

      controller.dispose();

      await completer.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('Stream onDone was not called after dispose'),
      );

      await sub.cancel();
    });
  });

  group('snapshot deduplication', () {
    test(
      'repeated same-state snapshots do not trigger redundant evaluations',
      () {
        fakeAsync((async) {
          final controller = _createController(
            de1Controller,
            settingsController: settingsCtrl,
          );
          controller.initialize();
          async.flushMicrotasks();

          de1Controller.setDe1(testDe1);
          async.flushMicrotasks();

          final emissions = <DisplayState>[];
          final sub = controller.state.listen(emissions.add);
          async.flushMicrotasks();

          final countAfterConnect = emissions.length;

          testDe1.emitState(MachineState.idle);
          async.flushMicrotasks();
          testDe1.emitState(MachineState.idle);
          async.flushMicrotasks();
          testDe1.emitState(MachineState.idle);
          async.flushMicrotasks();

          expect(emissions.length, countAfterConnect);

          sub.cancel();
          controller.dispose();
        });
      },
    );
  });

  group('DisplayState', () {
    test('toJson returns correct structure', () {
      const state = DisplayState(
        wakeLockEnabled: true,
        wakeLockOverride: false,
        brightness: 50,
        requestedBrightness: 80,
        lowBatteryBrightnessActive: true,
        platformSupported: DisplayPlatformSupport(
          brightness: true,
          wakeLock: true,
        ),
      );

      final json = state.toJson();
      expect(json['wakeLockEnabled'], isTrue);
      expect(json['wakeLockOverride'], isFalse);
      expect(json['brightness'], 50);
      expect(json['requestedBrightness'], 80);
      expect(json['lowBatteryBrightnessActive'], isTrue);
      expect(json['platformSupported'], isA<Map>());
      expect(json['platformSupported']['brightness'], isTrue);
      expect(json['platformSupported']['wakeLock'], isTrue);
    });

    test('copyWith preserves unmodified fields', () {
      const original = DisplayState(
        wakeLockEnabled: true,
        wakeLockOverride: true,
        brightness: 50,
        requestedBrightness: 80,
        lowBatteryBrightnessActive: true,
        platformSupported: DisplayPlatformSupport(
          brightness: true,
          wakeLock: true,
        ),
      );

      final copied = original.copyWith(wakeLockEnabled: false);
      expect(copied.wakeLockEnabled, isFalse);
      expect(copied.wakeLockOverride, isTrue);
      expect(copied.brightness, 50);
      expect(copied.requestedBrightness, 80);
      expect(copied.lowBatteryBrightnessActive, isTrue);
    });

    test('copyWith can change all fields', () {
      const original = DisplayState(
        wakeLockEnabled: false,
        wakeLockOverride: false,
        brightness: 100,
        requestedBrightness: 100,
        lowBatteryBrightnessActive: false,
        platformSupported: DisplayPlatformSupport(
          brightness: false,
          wakeLock: false,
        ),
      );

      final copied = original.copyWith(
        wakeLockEnabled: true,
        wakeLockOverride: true,
        brightness: 50,
        requestedBrightness: 80,
        lowBatteryBrightnessActive: true,
        platformSupported: const DisplayPlatformSupport(
          brightness: true,
          wakeLock: true,
        ),
      );

      expect(copied.wakeLockEnabled, isTrue);
      expect(copied.wakeLockOverride, isTrue);
      expect(copied.brightness, 50);
      expect(copied.requestedBrightness, 80);
      expect(copied.lowBatteryBrightnessActive, isTrue);
      expect(copied.platformSupported.brightness, isTrue);
      expect(copied.platformSupported.wakeLock, isTrue);
    });
  });
}
