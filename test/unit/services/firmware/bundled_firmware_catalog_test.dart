import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/firmware/bundled_firmware_catalog.dart';
import 'package:reaprime/src/services/firmware/firmware_validator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('production bundle contains valid 1352 and 1358 firmware', () async {
    final catalog = BundledFirmwareCatalog(bundle: rootBundle);
    final manifest = await catalog.loadManifest();

    expect(manifest.entries, hasLength(2));

    final byId = {for (final e in manifest.entries) e.artifact.id: e};
    expect(byId.keys, containsAll(['de1-1352', 'de1-1358']));

    expect(byId['de1-1352']!.artifact.build, 1352);
    expect(byId['de1-1358']!.artifact.build, 1358);

    for (final entry in manifest.entries) {
      expect(entry.artifact.supportedModels, {
        'DE1Pro',
        'DE1XL',
        'DE1XXL',
        'DE1XXXL',
      });

      final image = await catalog.loadImage(entry.artifact.id);
      const FirmwareValidator().validate(entry, image);
    }
    await catalog.verifyAllArtifacts();
  });
}
