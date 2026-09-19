class DiagnosticTimestamp {
  DateTime? _at;
  final Stopwatch _age = Stopwatch();

  void mark() {
    _at = DateTime.now().toUtc();
    _age.reset();
    _age.start();
  }

  Map<String, Object?> get snapshot => {
    'at': _at?.toIso8601String(),
    'ageMs': _at == null ? null : _age.elapsedMilliseconds,
  };
}
