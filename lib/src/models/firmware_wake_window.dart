library;

import 'package:reaprime/src/models/wake_schedule.dart';

/// Translation from Decaid's app-side [WakeSchedule] model to the Bengle
/// firmware weekly wake-table entries (MMR rows 55-57, 0x008038C0-0x008038C8),
/// verified against BengleMainCPUFirmware at tadelv/Bengle master 2377c7e0
/// (src/Classes/System.hpp setLocalTimeOfWeek / scheduleAddEntry /
/// scheduleControl, src/StateMachines/ShotMachine.cpp checkSchedule).

/// Maximum entries the firmware wake table accepts (MAX_AWAKE_WINDOWS).
const int kFirmwareMaxWakeWindows = 32;

/// Maximum minutes the firmware InactivitySleepTimeout register accepts.
/// A schedule without an explicit keep-awake window translates to a window
/// of this length — the longest unattended awake stretch the firmware can
/// represent ("wake for the day", product decision 2026-02-14).
const int kFirmwareMaxSleepTimeoutMinutes = 240;

/// One firmware wake window. `dow` is 0=Sunday .. 6=Saturday, `startMin` is
/// inclusive (0..1439), `endMin` is exclusive (1..1440). The firmware
/// rejects `startMin >= endMin`, so midnight-crossing windows are always
/// split into two entries app-side.
class FirmwareWakeWindow {
  const FirmwareWakeWindow({
    required this.dow,
    required this.startMin,
    required this.endMin,
  });

  final int dow;
  final int startMin;
  final int endMin;

  /// packed = (dow << 22) | (startMin << 11) | endMin
  int pack() => (dow << 22) | (startMin << 11) | endMin;

  @override
  bool operator ==(Object other) =>
      other is FirmwareWakeWindow &&
      other.dow == dow &&
      other.startMin == startMin &&
      other.endMin == endMin;

  @override
  int get hashCode => Object.hash(dow, startMin, endMin);

  @override
  String toString() => 'FirmwareWakeWindow(dow: $dow, $startMin..$endMin)';
}

/// Local wall-clock seconds since Sunday 00:00:00, computed from calendar
/// fields so DST transitions cannot skew the value AT PUSH TIME
/// (setLocalTimeOfWeek expects LOCAL time-of-week). The firmware clock is
/// RAM-only and re-pushed on connect and settings changes, so a DST or
/// timezone change during a long-lived connection is only picked up at the
/// next sync.
int localSecondsSinceSunday(DateTime now) {
  final daysSinceSunday = now.weekday % 7; // Dart: Mon=1..Sun=7 -> 0..6
  return daysSinceSunday * 86400 +
      now.hour * 3600 +
      now.minute * 60 +
      now.second;
}

/// Translate app schedules into firmware windows.
///
/// Rules (documented in doc/plans/bengle-feature-completion.md):
/// - disabled schedules are dropped;
/// - `keepAwakeFor=N` -> window [start, start+N);
/// - no `keepAwakeFor` -> window [start, start + 240) (firmware maximum);
/// - an empty `daysOfWeek` means every day (matches WakeSchedule.matchesTime);
/// - Dart weekday (Mon=1..Sun=7) -> firmware dow (`weekday % 7`);
/// - windows crossing midnight are split into [start, 1440) on day D and
///   [0, end) on day D+1; durations beyond a day keep splitting;
/// - the result is truncated to [kFirmwareMaxWakeWindows] entries.
List<FirmwareWakeWindow> translateWakeSchedules(List<WakeSchedule> schedules) {
  final windows = <FirmwareWakeWindow>[];
  for (final schedule in schedules) {
    if (!schedule.enabled) continue;
    final duration =
        (schedule.keepAwakeFor != null && schedule.keepAwakeFor! > 0)
        ? schedule.keepAwakeFor!
        : kFirmwareMaxSleepTimeoutMinutes;
    final start = schedule.hour * 60 + schedule.minute;
    final days = schedule.daysOfWeek.isEmpty
        ? const {1, 2, 3, 4, 5, 6, 7}
        : schedule.daysOfWeek;

    for (final dartDay in days) {
      var fwDow = dartDay % 7;
      var dayStart = start;
      var remaining = duration;
      while (remaining > 0 && windows.length < kFirmwareMaxWakeWindows) {
        final dayEnd = dayStart + remaining;
        final endMin = dayEnd > 1440 ? 1440 : dayEnd;
        windows.add(
          FirmwareWakeWindow(dow: fwDow, startMin: dayStart, endMin: endMin),
        );
        remaining -= (endMin - dayStart);
        dayStart = 0;
        fwDow = (fwDow + 1) % 7;
      }
    }
  }
  return windows;
}
