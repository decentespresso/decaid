class BuildInfo {
  static const String commit = String.fromEnvironment(
    'COMMIT',
    defaultValue: 'unknown',
  );
  static const String commitShort = String.fromEnvironment(
    'COMMIT_SHORT',
    defaultValue: 'unknown',
  );
  static const String branch = String.fromEnvironment(
    'BRANCH',
    defaultValue: 'unknown',
  );
  static const String buildTime = String.fromEnvironment(
    'BUILD_TIME',
    defaultValue: 'unknown',
  );
  static const String version = String.fromEnvironment(
    'VERSION',
    defaultValue: '0.0.0-dev',
  );
  static const String buildNumber = String.fromEnvironment(
    'BUILD_NUMBER',
    defaultValue: '0',
  );

  /// Whether this is an App Store build (iOS).
  /// Pass --dart-define=APP_STORE=true to enable.
  static const bool appStore = bool.fromEnvironment('APP_STORE');

  /// Full version string including build number (e.g., "1.2.3+456")
  static String get fullVersion => '$version+$buildNumber';
}
