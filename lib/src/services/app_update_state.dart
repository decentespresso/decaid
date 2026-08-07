enum AppUpdatePhase {
  idle,

  checking,

  available,

  downloading,

  installing,

  error,
}

class AppUpdateState {
  final AppUpdatePhase phase;

  final String currentVersion;

  final String? latestVersion;

  final String? releaseNotes;

  final String releaseUrl;

  final bool installable;

  final double? progress;

  final String? error;

  const AppUpdateState({
    required this.phase,
    required this.currentVersion,
    required this.releaseUrl,
    required this.installable,
    this.latestVersion,
    this.releaseNotes,
    this.progress,
    this.error,
  });

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    String? currentVersion,
    String? latestVersion,
    String? releaseNotes,
    String? releaseUrl,
    bool? installable,
    double? progress,
    String? error,
  }) {
    return AppUpdateState(
      phase: phase ?? this.phase,
      currentVersion: currentVersion ?? this.currentVersion,
      latestVersion: latestVersion ?? this.latestVersion,
      releaseNotes: releaseNotes ?? this.releaseNotes,
      releaseUrl: releaseUrl ?? this.releaseUrl,
      installable: installable ?? this.installable,
      progress: progress ?? this.progress,
      error: error ?? this.error,
    );
  }

  Map<String, dynamic> toJson() => {
    'phase': phase.name,
    'currentVersion': currentVersion,
    'latestVersion': latestVersion,
    'releaseNotes': releaseNotes,
    'releaseUrl': releaseUrl,
    'installable': installable,
    'progress': progress,
    'error': error,
  };
}
