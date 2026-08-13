import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/firmware_wake_window.dart';
import 'package:reaprime/src/models/wake_schedule.dart';

void main() {
  group('localSecondsSinceSunday', () {
    test('computes wall-clock seconds since Sunday 00:00:00', () {
      // Wednesday 2026-01-14 08:30:15 local. Dart weekday: Wed = 3.
      final now = DateTime(2026, 1, 14, 8, 30, 15);
      expect(localSecondsSinceSunday(now), 3 * 86400 + 8 * 3600 + 30 * 60 + 15);
    });

    test('Sunday is day 0', () {
      expect(localSecondsSinceSunday(DateTime(2026, 1, 11, 0, 0, 0)), 0);
      expect(localSecondsSinceSunday(DateTime(2026, 1, 11, 23, 59, 59)), 86399);
    });
  });

  group('translateWakeSchedules', () {
    WakeSchedule schedule({
      int hour = 6,
      int minute = 0,
      Set<int> daysOfWeek = const {1},
      bool enabled = true,
      int? keepAwakeFor,
    }) => WakeSchedule.create(
      hour: hour,
      minute: minute,
      daysOfWeek: daysOfWeek,
      enabled: enabled,
      keepAwakeFor: keepAwakeFor,
    );

    test('keepAwakeFor maps to an inclusive-start exclusive-end window', () {
      final windows = translateWakeSchedules([
        schedule(hour: 6, minute: 0, daysOfWeek: {1}, keepAwakeFor: 30),
      ]);
      expect(windows, [
        const FirmwareWakeWindow(dow: 1, startMin: 360, endMin: 390),
      ]);
    });

    test('no keepAwakeFor falls back to the 240-minute firmware maximum', () {
      final windows = translateWakeSchedules([
        schedule(hour: 23, minute: 0, daysOfWeek: {1}),
      ]);
      expect(windows, [
        const FirmwareWakeWindow(dow: 1, startMin: 1380, endMin: 1440),
        const FirmwareWakeWindow(dow: 2, startMin: 0, endMin: 180),
      ]);
    });

    test('midnight-crossing windows split into two entries', () {
      final windows = translateWakeSchedules([
        schedule(hour: 23, minute: 30, daysOfWeek: {1}, keepAwakeFor: 120),
      ]);
      expect(windows, [
        const FirmwareWakeWindow(dow: 1, startMin: 1410, endMin: 1440),
        const FirmwareWakeWindow(dow: 2, startMin: 0, endMin: 90),
      ]);
    });

    test('durations beyond a day keep splitting', () {
      final windows = translateWakeSchedules([
        schedule(hour: 0, minute: 0, daysOfWeek: {1}, keepAwakeFor: 2880),
      ]);
      expect(windows, hasLength(2));
      expect(
        windows[0],
        const FirmwareWakeWindow(dow: 1, startMin: 0, endMin: 1440),
      );
      expect(
        windows[1],
        const FirmwareWakeWindow(dow: 2, startMin: 0, endMin: 1440),
      );
    });

    test('Dart weekday maps to firmware dow (Mon=1..Sun=7 -> 1..6,0)', () {
      final windows = translateWakeSchedules([
        schedule(daysOfWeek: {7}), // Sunday
        schedule(hour: 7, daysOfWeek: {1}), // Monday
        schedule(hour: 8, daysOfWeek: {6}), // Saturday
      ]);
      expect(windows.map((w) => w.dow), [0, 1, 6]);
    });

    test('empty daysOfWeek means every day', () {
      final windows = translateWakeSchedules([schedule(daysOfWeek: const {})]);
      expect(windows.map((w) => w.dow), [1, 2, 3, 4, 5, 6, 0]);
    });

    test('disabled schedules are dropped', () {
      final windows = translateWakeSchedules([
        schedule(enabled: false),
        schedule(hour: 7, daysOfWeek: {2}),
      ]);
      expect(windows, [
        const FirmwareWakeWindow(dow: 2, startMin: 420, endMin: 660),
      ]);
    });

    test('packing matches (dow<<22)|(startMin<<11)|endMin', () {
      const window = FirmwareWakeWindow(dow: 3, startMin: 360, endMin: 390);
      expect(window.pack(), (3 << 22) | (360 << 11) | 390);
    });

    test('result is capped at 32 entries', () {
      final windows = translateWakeSchedules([
        schedule(daysOfWeek: const {}), // 7 days x 5 windows each
        schedule(hour: 1, daysOfWeek: const {}),
        schedule(hour: 2, daysOfWeek: const {}),
        schedule(hour: 3, daysOfWeek: const {}),
        schedule(hour: 4, daysOfWeek: const {}),
      ]);
      expect(windows.length, kFirmwareMaxWakeWindows);
    });
  });
}
