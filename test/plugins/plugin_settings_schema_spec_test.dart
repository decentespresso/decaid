import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:yaml/yaml.dart';

YamlMap _pluginSettingSchema() {
  final spec =
      loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;
  final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
  return schemas['PluginSettingSchema'] as YamlMap;
}

YamlMap _pluginManifestSchema() {
  final spec =
      loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;
  final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
  return schemas['PluginManifest'] as YamlMap;
}

List<Map<String, dynamic>> _bundledSettingSchemas() {
  final result = <Map<String, dynamic>>[];
  for (final entry in Directory('assets/plugins').listSync()) {
    final manifest = File('${entry.path}/manifest.json');
    if (!manifest.existsSync()) continue;
    final json =
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
    final settings = json['settings'] as Map<String, dynamic>? ?? {};
    for (final schema in settings.values) {
      if (schema is Map<String, dynamic>) result.add(schema);
    }
  }
  return result;
}

List<Directory> _bundledPluginDirs() {
  // Plugin dirs fetched from external repos at build time are gitignored;
  // their manifests are versioned in the plugin's own repository.
  final ignored = File('.gitignore')
      .readAsStringSync()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.startsWith('assets/plugins/') && line.endsWith('/'))
      .map((line) => line.substring('assets/plugins/'.length, line.length - 1))
      .toSet();
  return Directory('assets/plugins')
      .listSync()
      .whereType<Directory>()
      .where(
        (dir) => !ignored.contains(dir.path.split(Platform.pathSeparator).last),
      )
      .toList();
}

void main() {
  test('PluginManifest.settings is documented as a setting-schema map', () {
    final settings =
        (_pluginManifestSchema()['properties'] as YamlMap)['settings']
            as YamlMap;

    expect(
      settings['additionalProperties'],
      isA<YamlMap>().having(
        (m) => m[r'$ref'],
        r'$ref',
        '#/components/schemas/PluginSettingSchema',
      ),
      reason:
          'GET /api/v1/plugins returns the manifest schema for every setting, '
          'so an opaque object tells a client nothing',
    );
  });

  test(
    'PluginManifest.apiVersion is documented with the type it is sent as',
    () {
      final apiVersion =
          (_pluginManifestSchema()['properties'] as YamlMap)['apiVersion']
              as YamlMap;

      expect(apiVersion['type'], 'integer');
    },
  );

  test('PluginManifest permissions match runtime wire values', () {
    final properties = _pluginManifestSchema()['properties'] as YamlMap;
    final permissions = properties['permissions'] as YamlMap;
    final items = permissions['items'] as YamlMap;
    final documented = (items['enum'] as YamlList).cast<String>().toSet();
    final runtime = PluginPermissions.values
        .map((value) => value.wireName)
        .toSet();

    expect(documented, runtime);
  });

  test('every field bundled plugins use is documented', () {
    final documented = (_pluginSettingSchema()['properties'] as YamlMap).keys
        .cast<String>()
        .toSet();

    final used = <String>{};
    for (final schema in _bundledSettingSchemas()) {
      used.addAll(schema.keys);
    }

    expect(used, isNotEmpty);
    expect(
      used.difference(documented),
      isEmpty,
      reason:
          'a bundled plugin declares a setting field the OpenAPI spec does '
          'not describe',
    );
  });

  test('every setting type bundled plugins use is documented', () {
    final properties = _pluginSettingSchema()['properties'] as YamlMap;
    final documented = (properties['type'] as YamlMap)['enum'] as YamlList;

    final used = _bundledSettingSchemas()
        .map((schema) => schema['type'])
        .whereType<String>()
        .toSet();

    expect(used, isNotEmpty);
    expect(
      used.difference(documented.cast<String>().toSet()),
      isEmpty,
      reason: 'a bundled plugin declares a setting type the spec omits',
    );
  });

  test('label falls back to the setting key when absent or blank', () {
    expect(pluginSettingLabel('AutoUpload', {'type': 'boolean'}), 'AutoUpload');
    expect(pluginSettingLabel('AutoUpload', {'label': '  '}), 'AutoUpload');
    expect(pluginSettingLabel('AutoUpload', {'label': 42}), 'AutoUpload');
    expect(pluginSettingLabel('AutoUpload', 'not a map'), 'AutoUpload');
    expect(
      pluginSettingLabel('AutoUpload', {
        'label': '  Upload shots automatically  ',
      }),
      'Upload shots automatically',
    );
  });

  test('every bundled setting declares a label', () {
    final missing = <String>[];
    for (final entry in _bundledPluginDirs()) {
      final manifest = File('${entry.path}/manifest.json');
      if (!manifest.existsSync()) continue;
      final json =
          jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
      final settings = json['settings'] as Map<String, dynamic>? ?? {};
      for (final setting in settings.entries) {
        final schema = setting.value;
        if (schema is! Map<String, dynamic>) continue;
        final label = schema['label'];
        if (label is! String || label.trim().isEmpty) {
          missing.add('${json['id']}.${setting.key}');
        }
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'a bundled setting would render as its storage key instead of a '
          'human-friendly name',
    );
  });
}
