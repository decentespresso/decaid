/// A single file that failed to import.
class ImportError {
  final String filename;
  final String reason;
  final String? details;
  const ImportError({
    required this.filename,
    required this.reason,
    this.details,
  });
  @override
  String toString() => '$filename: $reason';
}

/// Results of scanning a de1app folder before import.
class ScanResult {
  final int shotCount;
  final int profileCount;
  final bool hasDyeGrinders;
  final bool hasSettings;
  final String sourcePath;
  final String? shotSource;
  const ScanResult({
    required this.shotCount,
    required this.profileCount,
    required this.hasDyeGrinders,
    required this.hasSettings,
    required this.sourcePath,
    this.shotSource,
  });
  int get totalItems => shotCount + profileCount;
  bool get isEmpty => totalItems == 0 && !hasDyeGrinders && !hasSettings;
}

/// Results of a completed import operation.
class ImportResult {
  final int shotsImported;
  final int shotsSkipped;
  final int profilesImported;
  final int profilesSkipped;
  final int beansCreated;
  final int beansSkipped;
  final int grindersCreated;
  final int grindersSkipped;
  final bool settingsApplied;
  final List<ImportError> errors;
  const ImportResult({
    this.shotsImported = 0,
    this.shotsSkipped = 0,
    this.profilesImported = 0,
    this.profilesSkipped = 0,
    this.beansCreated = 0,
    this.beansSkipped = 0,
    this.grindersCreated = 0,
    this.grindersSkipped = 0,
    this.settingsApplied = false,
    this.errors = const [],
  });

  factory ImportResult.fromBackupSections(Map<String, dynamic> sections) {
    int count(String section, String field) {
      final value = sections[section];
      if (value is! Map) return 0;
      return value[field] is int ? value[field] as int : 0;
    }

    final errors = <ImportError>[];
    for (final entry in sections.entries) {
      final value = entry.value;
      if (value is! Map || value['errors'] is! List) continue;
      for (final error in value['errors'] as List) {
        errors.add(ImportError(filename: entry.key, reason: '$error'));
      }
    }

    return ImportResult(
      shotsImported: count('shots', 'imported'),
      shotsSkipped: count('shots', 'skipped'),
      profilesImported: count('profiles', 'imported'),
      profilesSkipped: count('profiles', 'skipped'),
      beansCreated: count('beans', 'imported'),
      beansSkipped: count('beans', 'skipped'),
      grindersCreated: count('grinders', 'imported'),
      grindersSkipped: count('grinders', 'skipped'),
      errors: errors,
    );
  }

  bool get hasErrors => errors.isNotEmpty;
  ImportResult operator +(ImportResult other) {
    return ImportResult(
      shotsImported: shotsImported + other.shotsImported,
      shotsSkipped: shotsSkipped + other.shotsSkipped,
      profilesImported: profilesImported + other.profilesImported,
      profilesSkipped: profilesSkipped + other.profilesSkipped,
      beansCreated: beansCreated + other.beansCreated,
      beansSkipped: beansSkipped + other.beansSkipped,
      grindersCreated: grindersCreated + other.grindersCreated,
      grindersSkipped: grindersSkipped + other.grindersSkipped,
      settingsApplied: settingsApplied || other.settingsApplied,
      errors: [...errors, ...other.errors],
    );
  }
}

/// Progress callback for import operations.
class ImportProgress {
  final int current;
  final int total;
  final String phase;
  final int beansCreated;
  final int grindersCreated;
  const ImportProgress({
    required this.current,
    required this.total,
    required this.phase,
    this.beansCreated = 0,
    this.grindersCreated = 0,
  });
  double get fraction => total > 0 ? current / total : 0;
}
