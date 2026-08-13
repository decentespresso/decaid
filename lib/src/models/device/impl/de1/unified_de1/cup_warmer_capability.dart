part of 'unified_de1.dart';

/// Cup-warmer surfaces beyond the persisted setpoint (MatSetPoint, row 36):
/// the RAM-only manual enable (CupWarmerMode, row 50), the live mat
/// temperature (MatCurrentTemp, row 58) and the scheduled pre-warm
/// (rows 59-61).
///
/// Verified against BengleMainCPUFirmware at 2377c7e0 (System.cpp
/// controlMatTemp):
///
/// - Manual mode requires CupWarmerMode=1 AND machine Idle AND
///   MatSetPoint > 0. CupWarmerMode boots to 0 on every power cycle and is
///   deliberately NOT persisted, so the heater can never reactivate
///   unattended after a power cut.
/// - MatCurrentTemp is deg C x 10 on the wire; raw 0 means no valid
///   reading (NTC out of band), surfaced as null here.
/// - Preheat runs the mat from MatPreheatLeadMin before a scheduled wake
///   window until it closes, with the machine still ASLEEP (only the 24 V
///   rail runs), as long as the schedule is enabled, the clock is valid and
///   MatSetPoint > 0. MatPreheatEnable/MatPreheatLeadMin are persisted;
///   MatPreheatActive is 1 only when the schedule (not manual mode) drives
///   the mat.
mixin CupWarmerCapability on UnifiedDe1 {
  Future<void> setCupWarmerEnabled(bool enabled) async {
    await writeMmrInt(BengleMmr.cupWarmerMode, enabled ? 1 : 0);
  }

  Future<bool> getCupWarmerEnabled() async {
    return await readMmrInt(BengleMmr.cupWarmerMode) == 1;
  }

  /// Live mat temperature in deg C, or null when the firmware reports no
  /// valid reading (raw 0).
  Future<double?> getCupWarmerCurrentTemperature() async {
    final raw = await readMmrScaled(BengleMmr.matCurrentTemp);
    return raw <= 0 ? null : raw;
  }

  Future<void> setCupWarmerPreheat({
    required bool enabled,
    required int leadMinutes,
  }) async {
    await writeMmrInt(BengleMmr.matPreheatEnable, enabled ? 1 : 0);
    await writeMmrInt(BengleMmr.matPreheatLeadMin, leadMinutes.clamp(0, 120));
  }

  Future<CupWarmerPreheatState> getCupWarmerPreheatState() async {
    final enabled = await readMmrInt(BengleMmr.matPreheatEnable) == 1;
    final lead = await readMmrInt(BengleMmr.matPreheatLeadMin);
    final active = await readMmrInt(BengleMmr.matPreheatActive) == 1;
    return CupWarmerPreheatState(
      enabled: enabled,
      leadMinutes: lead,
      active: active,
    );
  }
}
