part of 'unified_de1.dart';

/// Firmware wake-schedule surface (MMR rows 54-57): the persisted
/// autonomous inactivity sleep timeout and the tablet-synced weekly wake
/// schedule (RAM-only clock + table).
///
/// Verified against BengleMainCPUFirmware at 2377c7e0:
///
/// - InactivitySleepTimeout (0x008038BC, RWD, persisted): minutes, 0 =
///   disabled, max 240. The firmware sleeps only when NO tablet is
///   connected; while a tablet is connected the tablet owns sleep. Decaid's
///   `sleepTimeoutMinutes` maps 1:1 (0 -> 0). Persisted, so it is pushed on
///   connect and on setting change, not continuously.
/// - SetLocalTimeOfWeek (0x008038C0): LOCAL time as seconds since Sunday
///   00:00:00. RAM-only (no RTC): must be re-pushed on every connect.
/// - ScheduleEntry (0x008038C4): one packed window, appended to the RAM-only
///   table (32 max).
/// - ScheduleControl (0x008038C8): 0 = clear table + disable; 1 = enable.
///
/// The rewrite sequence (control 0 -> entries -> control 1) is edge-safe:
/// currentAwakeWindowKey() reports NOT_READY mid-rewrite and preserves
/// LastWokenWindowKey, so a manual mid-window sleep is never re-woken by the
/// re-push (see ShotMachine.cpp checkSchedule).
mixin WakeScheduleCapability on UnifiedDe1 {
  Future<void> setInactivitySleepTimeout(int minutes) async {
    await writeMmrInt(
      BengleMmr.inactivitySleepTimeout,
      minutes.clamp(0, kFirmwareMaxSleepTimeoutMinutes),
    );
  }

  /// Push the local wall-clock and replace the whole wake table. An empty
  /// [windows] list clears and disables the table.
  Future<void> pushFirmwareWakeSchedule({
    required int secondsSinceSundayLocal,
    required List<FirmwareWakeWindow> windows,
  }) async {
    await writeMmrInt(
      BengleMmr.setLocalTimeOfWeek,
      secondsSinceSundayLocal.clamp(0, 604800),
    );
    await writeMmrInt(BengleMmr.scheduleControl, 0);
    for (final window in windows.take(kFirmwareMaxWakeWindows)) {
      await writeMmrInt(BengleMmr.scheduleEntry, window.pack());
    }
    if (windows.isNotEmpty) {
      await writeMmrInt(BengleMmr.scheduleControl, 1);
    }
  }
}
