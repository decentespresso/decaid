part of 'unified_de1.dart';

mixin CupWarmerCapability on UnifiedDe1 {
  Future<void> setCupWarmerEnabled(bool enabled) async {
    await writeMmrInt(BengleMmr.cupWarmerMode, enabled ? 1 : 0);
  }

  Future<bool> getCupWarmerEnabled() async {
    return await readMmrInt(BengleMmr.cupWarmerMode) == 1;
  }

  Future<double?> getCupWarmerCurrentTemperature() async {
    final raw = await readMmrScaled(BengleMmr.matCurrentTemp);
    return raw <= 0 ? null : raw;
  }

  Future<void> setCupWarmerPreheat({
    required bool enabled,
    required int leadMinutes,
  }) async {
    final lead = leadMinutes.clamp(0, 120);
    if (enabled) {
      await writeMmrInt(BengleMmr.matPreheatLeadMin, lead);
      await writeMmrInt(BengleMmr.matPreheatEnable, 1);
    } else {
      await writeMmrInt(BengleMmr.matPreheatEnable, 0);
      await writeMmrInt(BengleMmr.matPreheatLeadMin, lead);
    }
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
