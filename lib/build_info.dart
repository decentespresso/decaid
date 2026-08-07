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

  static const bool appStore = bool.fromEnvironment('APP_STORE');

  static String get fullVersion => '$version+$buildNumber';
}
