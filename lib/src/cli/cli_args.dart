import 'package:args/args.dart';

class CliArgs {
  final bool serial;
  final bool bypassOnboarding;
  final bool direct;
  final bool noAccount;
  final bool printStoragePaths;
  final Set<String> trustedConsentKeys;
  final bool trustAllConsent;
  final String? skinId;
  final String? skinPath;

  const CliArgs({
    this.serial = false,
    this.bypassOnboarding = false,
    this.direct = false,
    this.noAccount = false,
    this.printStoragePaths = false,
    this.trustedConsentKeys = const {},
    this.trustAllConsent = false,
    this.skinId,
    this.skinPath,
  });
}

CliArgs parseCliArgs(List<String> args) {
  final parser = ArgParser()
    ..addFlag('serial', help: 'Serial-only mode; skip BLE service creation.')
    ..addFlag(
      'bypass-onboarding',
      help: 'Skip onboarding screens (welcome, login, import).',
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
    );

  final results = parser.parse(args);
  return CliArgs(
    serial: results['serial'] as bool,
    bypassOnboarding: results['bypass-onboarding'] as bool,
    direct: results['direct'] as bool,
    noAccount: results['no-account'] as bool,
    printStoragePaths: results['print-storage-paths'] as bool,
    trustedConsentKeys: (results['trust-consent'] as List<String>).toSet(),
    trustAllConsent: results['trust-all-consent'] as bool,
    skinId: results['skin'] as String?,
    skinPath: results['skin-path'] as String?,
  );
}
