import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

  for (final entry in requiredPermissions.entries) {
    test('${entry.key} declares every capability it uses', () async {
      final json = jsonDecode(
        await File('assets/plugins/${entry.key}/manifest.json').readAsString(),
      );
      final manifest = PluginManifest.fromJson(json as Map<String, dynamic>);

      expect(manifest.permissions, containsAll(entry.value));
    });
  }
}
