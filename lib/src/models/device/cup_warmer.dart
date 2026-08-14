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
