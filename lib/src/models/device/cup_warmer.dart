/// Cup-warmer surfaces for Bengle firmware MMR rows 50/58-61, verified
/// against BengleMainCPUFirmware at tadelv/Bengle master 2377c7e0
/// (src/Classes/System.cpp controlMatTemp, MMR.def rows 50, 58-61).
library;

/// Scheduled pre-warm configuration and status.
///
/// `enabled` (MatPreheatEnable) and `leadMinutes` (MatPreheatLeadMin) are
/// persisted firmware configuration; `active` (MatPreheatActive) is
/// read-only and true when the wake schedule — not the manual
/// CupWarmerMode — is currently driving the mat.
class CupWarmerPreheatState {
  const CupWarmerPreheatState({
    required this.enabled,
    required this.leadMinutes,
    required this.active,
  });

  final bool enabled;
  final int leadMinutes;
  final bool active;

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'leadMinutes': leadMinutes,
    'active': active,
  };
}
