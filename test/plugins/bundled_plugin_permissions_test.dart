import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

void main() {
  const requiredPermissions = <String, Set<PluginPermissions>>{
    'time-to-ready.reaplugin': {
      PluginPermissions.log,
      PluginPermissions.emit,
      PluginPermissions.pluginStorage,
      PluginPermissions.eventsMachine,
    },
    'visualizer.reaplugin': {
      PluginPermissions.log,
      PluginPermissions.api,
      PluginPermissions.emit,
      PluginPermissions.pluginStorage,
      PluginPermissions.eventsMachine,
      PluginPermissions.eventsShots,
    },
    'settings.reaplugin': {PluginPermissions.log, PluginPermissions.api},
    'dye2.reaplugin': {PluginPermissions.log, PluginPermissions.api},
    'decent-profile.reaplugin': {
      PluginPermissions.log,
      PluginPermissions.api,
      PluginPermissions.emit,
    },
    'shot-upload.reaplugin': {
      PluginPermissions.log,
      PluginPermissions.api,
      PluginPermissions.emit,
      PluginPermissions.pluginStorage,
      PluginPermissions.proxyDecentApiWrite,
      PluginPermissions.eventsShots,
    },
  };
  const versionsBeforePermissionEnforcement = <String, String>{
    'time-to-ready.reaplugin': '1.0.2',
    'visualizer.reaplugin': '1.5.3',
    'decent-profile.reaplugin': '1.1.0',
    'shot-upload.reaplugin': '0.1.0',
  };

  for (final entry in requiredPermissions.entries) {
    test('${entry.key} declares every capability it uses', () async {
      final json = jsonDecode(
        await File('assets/plugins/${entry.key}/manifest.json').readAsString(),
      );
      final manifest = PluginManifest.fromJson(json as Map<String, dynamic>);

      expect(manifest.permissions, containsAll(entry.value));
      final previousVersion = versionsBeforePermissionEnforcement[entry.key];
      if (previousVersion != null) {
        expect(
          Version.parse(manifest.version),
          greaterThan(Version.parse(previousVersion)),
        );
      }
    });
  }
}
