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
      expect(
        githubPatMacOsOptions.accessibility,
        KeychainAccessibility.first_unlock_this_device,
      );
      expect(githubPatMacOsOptions.synchronizable, isFalse);
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

  test(
    'macOS keychain sharing capability is wired for both configurations',
    () {
      for (final path in [
        'macos/Runner/DebugProfile.entitlements',
        'macos/Runner/Release.entitlements',
      ]) {
        final entitlements = File(path).readAsStringSync();
        expect(entitlements, contains('<key>keychain-access-groups</key>'));
        expect(
          entitlements,
          contains('<key>keychain-access-groups</key>\n\t<array/>'),
        );
      }
    },
  );
}
