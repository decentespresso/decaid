import 'package:flutter_test/flutter_test.dart';

import '../plugins/extension_management_harness.dart';

const _securityKey = 'requireExtensionManagementAuthorization';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final protect in [false, true]) {
    group(protect ? 'protected mode' : 'compatibility mode', () {
      late ExtensionManagementHarness harness;

      setUp(() async {
        harness = await ExtensionManagementHarness.start(
          requireExtensionManagementAuthorization: protect,
        );
      });

      tearDown(() => harness.dispose());

      test(
        'a plugin settings write cannot reach the security setting',
        () async {
          const declared = 'declared.reaplugin';
          const plain = 'plain.reaplugin';
          await harness.loader.updatePluginSource(
            declared,
            manifestJson: {
              ...pluginManifestJson(
                declared,
                permissions: managementOnlyPermissions,
              ),
              'settings': {
                'mode': {'type': 'string'},
                _securityKey: {'type': 'boolean'},
              },
            },
            pluginJs: probePluginJs(declared),
          );
          await harness.loader.enablePlugin(declared);
          await harness.install(plain, permissions: managementOnlyPermissions);

          final refused = await harness.localApi(
            plain,
            '/api/v1/plugins/$plain/settings',
            options: {
              'method': 'POST',
              'body': {_securityKey: true},
            },
          );
          expect(refused.resolved, isTrue, reason: '$refused');
          expect(refused.status, 400, reason: '$refused');
          expect(
            refused.jsonBody['error'],
            contains('not defined in plugin manifest'),
            reason: '$refused',
          );

          final stored = await harness.localApi(
            plain,
            '/api/v1/plugins/$declared/settings',
            options: {
              'method': 'POST',
              'body': {_securityKey: true},
            },
          );
          expect(stored.status, 200, reason: '$stored');
          expect(
            await harness.loader.pluginSettings(declared),
            containsPair(_securityKey, true),
          );
          expect(
            await harness.loader.pluginSettings(plain),
            isNot(contains(_securityKey)),
          );
          expect(harness.settingsPosts, isEmpty);
          expect(harness.bridged, [
            'POST /api/v1/plugins/$plain/settings',
            'POST /api/v1/plugins/$declared/settings',
          ]);
        },
      );
    });
  }
}
