import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_version.dart';

void main() {
  Future<PluginManifest> bundledManifest(String id) async {
    final path = 'assets/plugins/$id/manifest.json';
    final json = jsonDecode(await File(path).readAsString());
    return PluginManifest.fromJson(json as Map<String, dynamic>);
  }

  test('settings bundled copy replaces the previously shipped 0.1.9', () async {
    final manifest = await bundledManifest('settings.reaplugin');
    final strictlyNewerInstall =
        '${Version.parse(manifest.version).major + 1}.0.0';

    expect(
      shouldReplaceBundledPlugin(manifest.version, '0.1.9'),
      isTrue,
      reason: 'stale copies would never receive the plugin.js fix',
    );
    expect(
      shouldReplaceBundledPlugin(manifest.version, manifest.version),
      isFalse,
    );
    expect(
      shouldReplaceBundledPlugin(manifest.version, strictlyNewerInstall),
      isFalse,
    );
  });
}
