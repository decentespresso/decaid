import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
