enum MachineSettingWriteStatus { applied, adjusted, unverified }

class MachineSettingWriteResult {
  final Object? requested;
  final Object? actual;
  final MachineSettingWriteStatus status;

  const MachineSettingWriteResult({
    required this.requested,
    required this.actual,
    required this.status,
  });

  factory MachineSettingWriteResult.verified({
    required Object? requested,
    required Object? actual,
    double tolerance = 0,
  }) => MachineSettingWriteResult(
    requested: requested,
    actual: actual,
    status: _matches(requested, actual, tolerance)
        ? MachineSettingWriteStatus.applied
        : MachineSettingWriteStatus.adjusted,
  );

  factory MachineSettingWriteResult.unverified(Object? requested) =>
      MachineSettingWriteResult(
        requested: requested,
        actual: null,
        status: MachineSettingWriteStatus.unverified,
      );

  static bool _matches(Object? requested, Object? actual, double tolerance) {
    if (requested is num && actual is num) {
      return (requested.toDouble() - actual.toDouble()).abs() <= tolerance;
    }
    return requested == actual;
  }

  Map<String, dynamic> toJson() => {
    'requested': requested,
    'actual': actual,
    'status': status.name,
  };
}

class MachineSettingsWriteReport {
  final Map<String, MachineSettingWriteResult> results;

  const MachineSettingsWriteReport(this.results);

  Map<String, dynamic> toJson() =>
      results.map((field, result) => MapEntry(field, result.toJson()));
}
