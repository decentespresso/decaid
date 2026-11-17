import 'package:args/args.dart';

const extensionsTokenEnvironmentVariable = 'DECAID_EXTENSIONS_TOKEN';

class CliArgs {
  final bool serial;
  final bool bypassOnboarding;
  final bool forceOnboarding;
  final bool direct;
  final bool noAccount;
  final bool dummyAccount;
  final bool printStoragePaths;
  final Set<String> trustedConsentKeys;
  final bool trustAllConsent;
  final String? extensionsToken;
  final String? extensionsTokenSource;
  final String? skinId;
  final String? skinPath;

  const CliArgs({
    this.serial = false,
    this.bypassOnboarding = false,
    this.forceOnboarding = false,
    this.direct = false,
    this.noAccount = false,
    this.dummyAccount = false,
    this.printStoragePaths = false,
    this.trustedConsentKeys = const {},
    this.trustAllConsent = false,
    this.extensionsToken,
    this.extensionsTokenSource,
    this.skinId,
    this.skinPath,
  });
}

CliArgs parseCliArgs(
  List<String> args, {
  Map<String, String> environment = const {},
}) {
  final parser = ArgParser()
    ..addFlag('serial', help: 'Serial-only mode; skip BLE service creation.')
    ..addFlag(
      'bypass-onboarding',
      help: 'Skip onboarding screens (welcome, login, import).',
    )
    ..addFlag(
      'force-onboarding',
      help:
          'Re-arm onboarding screens (welcome, login, import) by '
          'clearing their completion flags. Wins over --bypass-onboarding.',
    )
    ..addFlag(
      'direct',
      help: 'Auto-connect to first discovered machine/scale without picker.',
      defaultsTo: false,
    )
    ..addOption('skin', help: 'Set default skin ID from installed registry.')
    ..addOption('skin-path', help: 'Serve skin directly from filesystem path.')
    ..addFlag(
      'no-account',
      help: 'Bypass DecentAccountService (headless Linux with no keyring).',
      defaultsTo: false,
    )
    ..addFlag(
      'dummy-account',
      help:
          'Use an isolated in-memory demo identity. Requires a debug build '
          'with --dart-define=DECAID_ENABLE_DUMMY_ACCOUNT=true.',
      defaultsTo: false,
    )
    ..addFlag(
      'print-storage-paths',
      help: 'Print resolved application storage paths and exit.',
      defaultsTo: false,
    )
    ..addMultiOption(
      'trust-consent',
      help: 'Trust an account-consent key for this process.',
    )
    ..addFlag(
      'trust-all-consent',
      help: 'Trust every account-proxy caller for this process.',
      defaultsTo: false,
    )
    ..addOption(
      'extensions-token',
      help:
          'Accept this bearer token for plugin and skin management '
          '(extensions:manage) for this process. At least 32 characters, '
          'no spaces or commas; '
          'not persisted. For headless and development use. Other local '
          'users can read command-line arguments; set '
          '$extensionsTokenEnvironmentVariable instead to keep the value out '
          'of them.',
    );

  final results = parser.parse(args);
  final flagToken = results['extensions-token'] as String?;
  final environmentToken = environment[extensionsTokenEnvironmentVariable];
  return CliArgs(
    serial: results['serial'] as bool,
    bypassOnboarding: results['bypass-onboarding'] as bool,
    forceOnboarding:
        (results['force-onboarding'] as bool) ||
        const bool.fromEnvironment('forceOnboarding'),
    direct: results['direct'] as bool,
    noAccount: results['no-account'] as bool,
    dummyAccount:
        (results['dummy-account'] as bool) ||
        const bool.fromEnvironment('dummyAccount'),
    printStoragePaths: results['print-storage-paths'] as bool,
    trustedConsentKeys: (results['trust-consent'] as List<String>).toSet(),
    trustAllConsent: results['trust-all-consent'] as bool,
    extensionsToken: flagToken ?? environmentToken,
    extensionsTokenSource: flagToken != null
        ? '--extensions-token'
        : environmentToken != null
        ? extensionsTokenEnvironmentVariable
        : null,
    skinId: results['skin'] as String?,
    skinPath: results['skin-path'] as String?,
  );
}
