import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/github_credentials.dart';

void main() {
  test(
    'PAT storage uses isolated Android and non-synchronizing Apple options',
    () {
      expect(
        githubPatAndroidOptions.toMap()['sharedPreferencesName'],
        githubPatAndroidSharedPreferencesName,
      );
      expect(
        githubPatAndroidOptions.toMap()['preferencesKeyPrefix'],
        githubPatAndroidKeyPrefix,
      );
      expect(
        githubPatAndroidOptions.toMap()['migrateOnAlgorithmChange'],
        'true',
      );
      expect(
        githubPatIosOptions.accessibility,
        KeychainAccessibility.first_unlock_this_device,
      );
      expect(githubPatIosOptions.synchronizable, isFalse);
    },
  );

  test('Android manifest and backup rules exclude only PAT preferences', () {
    const prefsFile = 'decaid_github_pat.xml';
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final legacyRules = File(
      'android/app/src/main/res/xml/github_pat_backup_rules.xml',
    ).readAsStringSync();
    final extractionRules = File(
      'android/app/src/main/res/xml/github_pat_data_extraction_rules.xml',
    ).readAsStringSync();

    expect(
      manifest,
      contains('android:fullBackupContent="@xml/github_pat_backup_rules"'),
    );
    expect(
      manifest,
      contains(
        'android:dataExtractionRules="@xml/github_pat_data_extraction_rules"',
      ),
    );
    expect(
      legacyRules,
      contains('<exclude domain="sharedpref" path="$prefsFile" />'),
    );
    expect(
      extractionRules,
      contains('<exclude domain="sharedpref" path="$prefsFile" />'),
    );
    expect(legacyRules, contains('<full-backup-content>'));
    expect(extractionRules, contains('<cloud-backup>'));
    expect(extractionRules, contains('<device-transfer>'));
    expect(RegExp(r'<exclude\b').allMatches(legacyRules), hasLength(1));
    expect(RegExp(r'<exclude\b').allMatches(extractionRules), hasLength(2));
  });

  test('Decent account storage defaults remain unchanged', () {
    final store = File('lib/src/services/account/credential_store.dart')
        .readAsStringSync();
    final factory = File(
      'lib/src/services/account/credential_store_factory.dart',
    ).readAsStringSync();

    expect(store, contains('AndroidOptions(migrateOnAlgorithmChange: true)'));
    expect(factory, contains('return SecureCredentialStore();'));
    expect(store, isNot(contains(githubPatAndroidSharedPreferencesName)));
    expect(factory, isNot(contains(githubPatAndroidSharedPreferencesName)));
  });

  test('PAT file creation uses an absolute same-directory mktemp template', () {
    final source = File('lib/src/services/github_credential_store.dart')
        .readAsStringSync();
    final mktemp = source.indexOf("Process.run('/usr/bin/mktemp'");
    final write = source.indexOf('writeAsBytes(bytes');
    expect(mktemp, greaterThanOrEqualTo(0));
    expect(write, greaterThan(mktemp));
    final normalized = source.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      normalized,
      contains(
        "final template = p.join( directory, '.github_pat_secure_storage_v1.XXXXXX', );",
      ),
    );
    expect(source, contains("Process.run('/usr/bin/mktemp', [template])"));
  });

  test('macOS PAT storage does not require a keychain entitlement', () {
    for (final path in [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      final entitlements = File(path).readAsStringSync();
      expect(entitlements, isNot(contains('keychain-access-groups')));
    }
  });
}
