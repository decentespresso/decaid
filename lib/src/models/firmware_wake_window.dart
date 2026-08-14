import 'package:reaprime/src/models/wake_schedule.dart';

const int kFirmwareMaxWakeWindows = 32;

const int kFirmwareMaxSleepTimeoutMinutes = 240;

class FirmwareWakeWindow {
  const FirmwareWakeWindow({
    required this.dow,
    required this.startMin,
    required this.endMin,
  });

  final int dow;
  final int startMin;
  final int endMin;

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

int localSecondsSinceSunday(DateTime now) {
  final daysSinceSunday = now.weekday % 7;
  return daysSinceSunday * 86400 +
      now.hour * 3600 +
      now.minute * 60 +
      now.second;
}

List<FirmwareWakeWindow> translateWakeSchedules(List<WakeSchedule> schedules) {
  final windows = <FirmwareWakeWindow>[];
  for (final schedule in schedules) {
    if (!schedule.enabled) continue;
    final duration =
        (schedule.keepAwakeFor != null && schedule.keepAwakeFor! > 0)
        ? schedule.keepAwakeFor!
        : kFirmwareMaxSleepTimeoutMinutes;
    if (schedule.hour < 0 ||
        schedule.hour > 23 ||
        schedule.minute < 0 ||
        schedule.minute > 59) {
      continue;
    }
    final start = schedule.hour * 60 + schedule.minute;
    final days = schedule.daysOfWeek.isEmpty
        ? const {1, 2, 3, 4, 5, 6, 7}
        : schedule.daysOfWeek;

    for (final dartDay in days) {
      if (dartDay < 1 || dartDay > 7) continue;
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
