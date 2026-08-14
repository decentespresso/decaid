part of 'unified_de1.dart';

mixin WakeScheduleCapability on UnifiedDe1 {
  Future<void> setInactivitySleepTimeout(int minutes) async {
    await writeMmrInt(
      BengleMmr.inactivitySleepTimeout,
      minutes.clamp(0, kFirmwareMaxSleepTimeoutMinutes),
    );
  }

  Future<void> pushFirmwareWakeSchedule({
    required int secondsSinceSundayLocal,
    required List<FirmwareWakeWindow> windows,
  }) async {
    await writeMmrInt(BengleMmr.scheduleControl, 0);
    await writeMmrInt(
      BengleMmr.setLocalTimeOfWeek,
      secondsSinceSundayLocal.clamp(0, 604800),
    );
    for (final window in windows.take(kFirmwareMaxWakeWindows)) {
      await writeMmrInt(BengleMmr.scheduleEntry, window.pack());
    }
    if (windows.isNotEmpty) {
      await writeMmrInt(BengleMmr.scheduleControl, 1);
    }
  }
}
