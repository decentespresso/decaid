import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/models/device/bengle_interface.dart';
import 'package:reaprime/src/models/device/cup_warmer.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/led_strip.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/subjects.dart';

import '../helpers/mock_settings_service.dart';

class _FakeBengle extends MockDe1 implements BengleInterface {
  _FakeBengle({this.supportsCurrentFirmwareSurface = true});

  final bool supportsCurrentFirmwareSurface;

  @override
  DeviceImplementation get implementation => DeviceImplementation.bengle;

  @override
  bool get supportsCurrentBengleFirmwareSurface =>
      supportsCurrentFirmwareSurface;

  final List<int> pushedTimeouts = [];
  final List<int> pushedClockSeconds = [];
  final List<List<FirmwareWakeWindow>> pushedWindows = [];

  /// When set, pushFirmwareWakeSchedule awaits this before recording, so
  /// tests can hold a push in flight while more triggers arrive.
  Completer<void>? pushGate;

  /// When > 0, the next pushFirmwareWakeSchedule throws instead of
  /// recording (simulates a failed transaction).
  int failNextPushes = 0;

  /// Number of pushes currently in flight (for single-flight assertions).
  int activePushes = 0;
  int maxConcurrentPushes = 0;

  @override
  Future<void> setInactivitySleepTimeout(int minutes) async {
    pushedTimeouts.add(minutes);
  }

  @override
  Future<void> pushFirmwareWakeSchedule({
    required int secondsSinceSundayLocal,
    required List<FirmwareWakeWindow> windows,
  }) async {
    activePushes++;
    if (activePushes > maxConcurrentPushes) {
      maxConcurrentPushes = activePushes;
    }
    try {
      final gate = pushGate;
      if (gate != null) {
        await gate.future;
      }
      if (failNextPushes > 0) {
        failNextPushes--;
        throw StateError('simulated push failure');
      }
      pushedClockSeconds.add(secondsSinceSundayLocal);
      pushedWindows.add(List.of(windows));
    } finally {
      activePushes--;
    }
  }

  @override
  Future<void> setCupWarmerTemperature(double celsius) async {}
  @override
  Future<double> getCupWarmerTemperature() async => 0.0;
  @override
  Future<void> setCupWarmerEnabled(bool enabled) async {}
  @override
  Future<bool> getCupWarmerEnabled() async => false;
  @override
  Future<double?> getCupWarmerCurrentTemperature() async => null;
  @override
  Future<void> setCupWarmerPreheat({
    required bool enabled,
    required int leadMinutes,
  }) async {}
  @override
  Future<CupWarmerPreheatState> getCupWarmerPreheatState() async =>
      const CupWarmerPreheatState(
        enabled: false,
        leadMinutes: 0,
        active: false,
      );
  @override
  Stream<LedStripState?> get ledStripState => const Stream.empty();
  @override
  Future<LedStripState?> getLedStripState() async => null;
  @override
  Future<void> setLedStrip(LedStripState state) async {}
  @override
  Future<void> commitLedStrip() async {}
  @override
  Future<LedStripState?> resetLedStrip() async => null;
  @override
  Future<ScaleCalibrationState> getScaleCalibrationState() async =>
      const ScaleCalibrationState(
        step: ScaleCalibrationStep.idle,
        detectedCell: ScaleCalibrationCell.none,
        subState: ScaleCalibrationSubState.settling,
        secondsRemaining: 0,
        status: ScaleCalibrationStatus.none,
      );
  @override
  Future<bool> startScaleCalibration(
    ScaleCalibrationCommand command, {
    double? weightGrams,
  }) async => true;
  @override
  Stream<ScaleSnapshot> get weightSnapshot => const Stream.empty();
  @override
  Future<void> tareIntegratedScale() async {}
  @override
  Future<void> setStopAtWeightTarget(double grams) async {}
  @override
  Future<double> getStopAtWeightTarget() async => 0.0;
  @override
  Stream<double> get stopAtWeightTarget => const Stream.empty();
  @override
  Future<void> setStopAtTemperatureTarget(double celsius) async {}
  @override
  Future<double> getStopAtTemperatureTarget() async => 0.0;
  @override
  Stream<double> get stopAtTemperatureTarget => const Stream.empty();
  @override
  Stream<bool> get probeAttached => const Stream.empty();
  @override
  Stream<double> get probeTemperature => const Stream.empty();
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
  late _FakeBengle bengle;

  setUp(() async {
    final deviceController = DeviceController([]);
    de1Controller = _TestDe1Controller(controller: deviceController);
    final mockSettings = MockSettingsService();
    settingsController = SettingsController(mockSettings);
    await settingsController.loadSettings();
    bengle = _FakeBengle();
  });

  void setSchedules(List<WakeSchedule> schedules) {
    settingsController.setWakeSchedules(WakeSchedule.serializeList(schedules));
  }

  test('connect pushes sleep timeout, clock and wake table', () {
    fakeAsync((async) {
      setSchedules([
        WakeSchedule.create(
          hour: 7,
          minute: 30,
          daysOfWeek: {1, 7}, // Monday, Sunday
          keepAwakeFor: 45,
        ),
      ]);
      settingsController.setSleepTimeoutMinutes(90);

      final controller = PresenceController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        clock: () => clock.now(),
      );
      controller.initialize();
      de1Controller.setDe1(bengle);
      async.flushMicrotasks();

      expect(bengle.pushedTimeouts, [90]);
      expect(bengle.pushedClockSeconds, [localSecondsSinceSunday(clock.now())]);
      expect(bengle.pushedWindows, hasLength(1));
      // Monday (Dart 1) -> firmware dow 1; Sunday (Dart 7) -> firmware dow 0.
      expect(bengle.pushedWindows.single, [
        const FirmwareWakeWindow(dow: 1, startMin: 450, endMin: 495),
        const FirmwareWakeWindow(dow: 0, startMin: 450, endMin: 495),
      ]);

      controller.dispose();
    });
  });

  test('disabling the master toggle pushes timeout 0 and no windows', () {
    fakeAsync((async) {
      final controller = PresenceController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        clock: () => clock.now(),
      );
      controller.initialize();
      de1Controller.setDe1(bengle);
      async.flushMicrotasks();
      expect(bengle.pushedTimeouts, [30]); // default 30

      settingsController.setUserPresenceEnabled(false);
      async.flushMicrotasks();
      expect(bengle.pushedTimeouts, [30, 0]);
      expect(bengle.pushedWindows.last, isEmpty);

      settingsController.setSleepTimeoutMinutes(45);
      async.flushMicrotasks();
      expect(bengle.pushedTimeouts, [30, 0]);

      settingsController.setUserPresenceEnabled(true);
      async.flushMicrotasks();
      expect(bengle.pushedTimeouts, [30, 0, 45]);
      expect(bengle.pushedWindows, hasLength(3));

      controller.dispose();
    });
  });

  test('connect while the master toggle is off pushes disabled state', () {
    fakeAsync((async) {
      settingsController.setUserPresenceEnabled(false);
      setSchedules([
        WakeSchedule.create(hour: 7, minute: 30, daysOfWeek: {1}),
      ]);
      settingsController.setSleepTimeoutMinutes(90);

      final controller = PresenceController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        clock: () => clock.now(),
      );
      controller.initialize();
      de1Controller.setDe1(bengle);
      async.flushMicrotasks();

      expect(bengle.pushedTimeouts, [0]);
      expect(bengle.pushedWindows.single, isEmpty);

      controller.dispose();
    });
  });

  test('schedule change re-pushes the table', () {
    fakeAsync((async) {
      final controller = PresenceController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        clock: () => clock.now(),
      );
      controller.initialize();
      de1Controller.setDe1(bengle);
      async.flushMicrotasks();
      expect(bengle.pushedWindows.single, isEmpty);

      setSchedules([
        WakeSchedule.create(hour: 6, minute: 0, daysOfWeek: {2}),
      ]);
      async.flushMicrotasks();
      expect(bengle.pushedWindows, hasLength(2));
      // No keepAwakeFor -> firmware max (240 min) window, Tue (dow 2).
      expect(bengle.pushedWindows.last, [
        const FirmwareWakeWindow(dow: 2, startMin: 360, endMin: 600),
      ]);

      controller.dispose();
    });
  });

  test('overlapping triggers coalesce and never interleave', () {
    fakeAsync((async) {
      final controller = PresenceController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        clock: () => clock.now(),
      );
      controller.initialize();
      de1Controller.setDe1(bengle);
      async.flushMicrotasks();
      expect(bengle.pushedWindows, hasLength(1)); // connect push

      setSchedules([
        WakeSchedule.create(hour: 6, minute: 0, daysOfWeek: {2}),
      ]);
      bengle.pushGate = Completer<void>();
      async.flushMicrotasks();
      expect(bengle.activePushes, 1);

      setSchedules([
        WakeSchedule.create(hour: 8, minute: 0, daysOfWeek: {3}),
      ]);
      async.flushMicrotasks();
      expect(
        bengle.activePushes,
        1,
        reason: 'a second push must not start while one is in flight',
      );

      bengle.pushGate!.complete();
      bengle.pushGate = null;
      async.flushMicrotasks();

      expect(bengle.maxConcurrentPushes, 1);
      expect(bengle.pushedWindows.last, [
        const FirmwareWakeWindow(dow: 3, startMin: 480, endMin: 720),
      ]);

      controller.dispose();
    });
  });

  test(
    'a failed push retries automatically and converges without new triggers',
    () {
      fakeAsync((async) {
        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(bengle);
        bengle.failNextPushes = 1;
        async.flushMicrotasks();

        expect(bengle.pushedWindows, isEmpty);

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(bengle.pushedWindows, hasLength(1));
        expect(bengle.pushedWindows.single, isEmpty);
        expect(bengle.pushedTimeouts, [30, 30]);

        controller.dispose();
      });
    },
  );

  test('a failed master-disable push retries until firmware owns no timeout '
      'or table', () {
    fakeAsync((async) {
      final controller = PresenceController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        clock: () => clock.now(),
      );
      controller.initialize();
      de1Controller.setDe1(bengle);
      async.flushMicrotasks();
      expect(bengle.pushedTimeouts, [30]);

      settingsController.setUserPresenceEnabled(false);
      bengle.failNextPushes = 1;
      async.flushMicrotasks();
      expect(bengle.pushedTimeouts.last, 0);
      expect(bengle.pushedWindows, [[]]);

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(bengle.pushedTimeouts, [30, 0, 0]);
      expect(bengle.pushedWindows, [[], []]);

      controller.dispose();
    });
  });

  test(
    'a newer trigger during the retry backoff supersedes the failed attempt',
    () {
      fakeAsync((async) {
        final controller = PresenceController(
          de1Controller: de1Controller,
          settingsController: settingsController,
          clock: () => clock.now(),
        );
        controller.initialize();
        de1Controller.setDe1(bengle);
        async.flushMicrotasks();

        setSchedules([
          WakeSchedule.create(hour: 6, minute: 0, daysOfWeek: {2}),
        ]);
        bengle.failNextPushes = 1;
        async.flushMicrotasks();
        expect(bengle.pushedWindows, [[]]);

        setSchedules([
          WakeSchedule.create(hour: 8, minute: 0, daysOfWeek: {3}),
        ]);
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(bengle.pushedWindows, hasLength(2));
        expect(bengle.pushedWindows.last, [
          const FirmwareWakeWindow(dow: 3, startMin: 480, endMin: 720),
        ]);
        expect(
          bengle.pushedWindows,
          isNot(
            contains([
              const FirmwareWakeWindow(dow: 2, startMin: 360, endMin: 600),
            ]),
          ),
          reason: 'the failed 6:00 state must be superseded, not retried',
        );

        controller.dispose();
      });
    },
  );

  test('a mid-flight replacement gets its own full push', () {
    fakeAsync((async) {
      final controller = PresenceController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        clock: () => clock.now(),
      );
      controller.initialize();
      de1Controller.setDe1(bengle);
      async.flushMicrotasks();
      expect(bengle.pushedTimeouts, [30]);

      setSchedules([
        WakeSchedule.create(hour: 6, minute: 0, daysOfWeek: {2}),
      ]);
      bengle.pushGate = Completer<void>();
      async.flushMicrotasks();

      final replacement = _FakeBengle();
      de1Controller.setDe1(replacement);
      async.flushMicrotasks();

      bengle.pushGate!.complete();
      bengle.pushGate = null;
      async.flushMicrotasks();

      expect(replacement.pushedTimeouts, [30]);
      expect(replacement.pushedWindows, hasLength(1));
      expect(replacement.pushedWindows.single, [
        const FirmwareWakeWindow(dow: 2, startMin: 360, endMin: 600),
      ]);

      controller.dispose();
    });
  });

  test('reconnect re-pushes even when the app values did not change', () {
    fakeAsync((async) {
      final controller = PresenceController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        clock: () => clock.now(),
      );
      controller.initialize();
      de1Controller.setDe1(bengle);
      async.flushMicrotasks();
      expect(bengle.pushedTimeouts, [30]);

      final replacement = _FakeBengle();
      de1Controller.setDe1(replacement);
      async.flushMicrotasks();
      expect(replacement.pushedTimeouts, [30]);

      controller.dispose();
    });
  });

  test('outdated firmware and plain DE1 get no firmware pushes', () {
    fakeAsync((async) {
      final controller = PresenceController(
        de1Controller: de1Controller,
        settingsController: settingsController,
        clock: () => clock.now(),
      );
      controller.initialize();

      final outdatedFirmware = _FakeBengle(
        supportsCurrentFirmwareSurface: false,
      );
      de1Controller.setDe1(outdatedFirmware);
      async.flushMicrotasks();
      expect(outdatedFirmware.pushedTimeouts, isEmpty);
      expect(outdatedFirmware.pushedWindows, isEmpty);

      de1Controller.setDe1(MockDe1());
      async.flushMicrotasks();

      controller.dispose();
    });
  });
}
