import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:yaml/yaml.dart';

const _schemeName = 'extensionsManage';

const _protectionCondition = 'protection is ON';

const _retiredRequirementClaim =
    'Requires `Authorization: Bearer <token>` scoped `extensions:manage`';

const _nativeOnlySetting = 'requireExtensionManagementAuthorization';

const _retiredExceptionMarkers = [
  'tokenless',
  'loopback',
  'retry-after',
  'automatic update checks are enabled in native settings',
];

const _mutatingMethods = {'post', 'put', 'patch', 'delete'};

const _httpMethods = {
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
};

const _guardedPrefixes = ['/api/v1/plugins', '/api/v1/webui'];

const _reviewedOpenPaths = {'/api/v1/plugins/{id}/{endpoint}'};

YamlMap _spec() =>
    loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;

typedef _Operation = ({String method, String path, YamlMap definition});

List<_Operation> _operations(YamlMap spec) {
  final result = <_Operation>[];
  final paths = spec['paths'] as YamlMap;
  for (final entry in paths.entries) {
    final path = entry.key as String;
    final item = entry.value as YamlMap;
    for (final method in item.keys.cast<String>()) {
      if (!_httpMethods.contains(method)) continue;
      result.add((
        method: method.toUpperCase(),
        path: path,
        definition: item[method] as YamlMap,
      ));
    }
  }
  return result;
}

List<String> _descriptions(YamlMap definition) {
  final texts = <String>[];
  final description = definition['description'];
  if (description is String) texts.add(description);
  final responses = definition['responses'];
  if (responses is YamlMap) {
    for (final response in responses.values) {
      if (response is YamlMap && response['description'] is String) {
        texts.add(response['description'] as String);
      }
    }
  }
  return texts;
}

YamlMap _schema(YamlMap spec, String name) =>
    ((spec['components'] as YamlMap)['schemas'] as YamlMap)[name] as YamlMap;

YamlMap _schemaProperties(YamlMap spec, String name) =>
    _schema(spec, name)['properties'] as YamlMap;

bool _declaresExtensionsManage(YamlMap operation) {
  final security = operation['security'];
  if (security is! YamlList) return false;
  return security.any(
    (requirement) =>
        requirement is YamlMap && requirement.containsKey(_schemeName),
  );
}

String _specPath(String routerPath) =>
    routerPath.replaceAllMapped(RegExp(r'<(\w+)>'), (m) => '{${m[1]}}');

String _key(String method, String path) => '$method $path';

void main() {
  final spec = _spec();
  final operations = _operations(spec);
  final protectedRoutes = {
    for (final route in extensionManagementRoutes)
      _key(route.method, _specPath(route.path)),
  };
  final declaringOperations = [
    for (final operation in operations)
      if (_declaresExtensionsManage(operation.definition)) operation,
  ];

  test('extensionsManage is an http bearer security scheme', () {
    final components = spec['components'] as YamlMap;
    final schemes = components['securitySchemes'] as YamlMap;
    final scheme = schemes[_schemeName] as YamlMap;
    expect(scheme['type'], 'http');
    expect(scheme['scheme'], 'bearer');
  });

  test('the spec protects exactly the routes the middleware protects', () {
    final declared = {
      for (final operation in declaringOperations)
        _key(operation.method, operation.path),
    };
    expect(declared, protectedRoutes);
  });

  test('every protected operation offers the tokenless alternative', () {
    for (final operation in declaringOperations) {
      final label = _key(operation.method, operation.path);
      final security = operation.definition['security'];
      expect(security, isA<YamlList>(), reason: '$label must declare security');
      final requirements = (security as YamlList).whereType<YamlMap>().toList();
      expect(
        requirements.where((requirement) => requirement.isEmpty),
        hasLength(1),
        reason:
            '$label must keep the empty security requirement {} so a client '
            'reads the credential as optional while protection is OFF',
      );
      expect(
        requirements.where(
          (requirement) => requirement.containsKey(_schemeName),
        ),
        hasLength(1),
        reason: '$label must keep the $_schemeName alternative',
      );
      expect(
        requirements,
        hasLength(2),
        reason: '$label must not carry a third security alternative',
      );
    }
  });

  test('no global security requirement applies the scheme elsewhere', () {
    expect(spec['security'], isNull);
  });

  test('every protected route exists in the spec', () {
    final documented = {
      for (final operation in operations)
        _key(operation.method, operation.path),
    };
    expect(protectedRoutes.difference(documented), isEmpty);
  });

  test('every protected operation documents 401 and 403', () {
    for (final operation in declaringOperations) {
      final responses = operation.definition['responses'] as YamlMap;
      final codes = responses.keys.map((code) => '$code').toSet();
      expect(
        codes,
        containsAll(['401', '403']),
        reason:
            '${_key(operation.method, operation.path)} must document 401 '
            'and 403',
      );
    }
  });

  test('every protected operation describes its requirement conditionally', () {
    for (final operation in declaringOperations) {
      final label = _key(operation.method, operation.path);
      final description = operation.definition['description'];
      expect(description, isA<String>(), reason: '$label needs a description');
      expect(
        description as String,
        contains(_protectionCondition),
        reason:
            '$label must say its credential is needed only while protection '
            'is ON, so a generated client does not demand one unconditionally',
      );
      expect(
        description,
        isNot(contains(_retiredRequirementClaim)),
        reason: '$label still states the retired unconditional requirement',
      );
    }
  });

  test('every protected refusal is documented as protection-only', () {
    for (final operation in declaringOperations) {
      final label = _key(operation.method, operation.path);
      final responses = operation.definition['responses'] as YamlMap;
      for (final code in ['401', '403']) {
        final response = responses[code];
        expect(response, isA<YamlMap>(), reason: '$label must document $code');
        final description = (response as YamlMap)['description'];
        expect(
          description,
          isA<String>(),
          reason: '$label $code needs a description',
        );
        expect(
          description as String,
          contains(_protectionCondition),
          reason: '$label $code must not claim the refusal applies when OFF',
        );
      }
    }
  });

  test('no protected operation documents a retired tokenless exception', () {
    for (final operation in declaringOperations) {
      final label = _key(operation.method, operation.path);
      final text = _descriptions(operation.definition).join('\n').toLowerCase();
      for (final marker in _retiredExceptionMarkers) {
        expect(
          text,
          isNot(contains(marker)),
          reason: '$label still mentions "$marker"',
        );
      }
    }
  });

  test('the spec never describes the retired tokenless update exception', () {
    final text = File('assets/api/rest_v1.yml')
        .readAsStringSync()
        .toLowerCase();
    expect(text, isNot(contains('tokenless')));
    expect(text, isNot(contains('native confirmation ships')));
  });

  test('the security scheme marks the credential as protection-only', () {
    final schemes =
        (spec['components'] as YamlMap)['securitySchemes'] as YamlMap;
    final scheme = schemes[_schemeName] as YamlMap;
    expect('${scheme['description']}', contains(_protectionCondition));
  });

  test('the body-dependent settings gate is described conditionally', () {
    final settings = operations.firstWhere(
      (operation) =>
          operation.method == 'POST' && operation.path == '/api/v1/settings',
    );
    final responses = settings.definition['responses'] as YamlMap;
    expect(settings.definition['description'], contains(_protectionCondition));
    for (final code in ['401', '403']) {
      final response = responses[code] as YamlMap;
      expect(
        response['description'],
        contains(_protectionCondition),
        reason: 'POST /api/v1/settings $code must apply only while ON',
      );
    }
    for (final key in ['webUiPath', 'defaultSkinId', 'automaticUpdateCheck']) {
      final property =
          _schemaProperties(spec, 'ReaSettingsRequest')[key] as YamlMap;
      expect(
        property['description'],
        contains(_protectionCondition),
        reason: 'ReaSettingsRequest.$key must describe the ON-only gate',
      );
    }
  });

  test('import and pull-sync gates are described conditionally', () {
    for (final path in ['/api/v1/data/import', '/api/v1/data/sync']) {
      final operation = operations.firstWhere(
        (candidate) => candidate.method == 'POST' && candidate.path == path,
      );
      expect(
        operation.definition['description'],
        contains(_protectionCondition),
        reason: 'POST $path must describe the ON-only settings gate',
      );
    }
  });

  test('the native-only policy setting has no REST field', () {
    final text = File('assets/api/rest_v1.yml').readAsStringSync();
    expect(text, isNot(contains(_nativeOnlySetting)));
    for (final schema in ['ReaSettings', 'ReaSettingsRequest']) {
      expect(
        _schemaProperties(spec, schema).containsKey(_nativeOnlySetting),
        isFalse,
        reason:
            '$schema must not carry the native Security toggle as a property',
      );
    }
  });

  test('every plugin and skin mutation is protected or reviewed as open', () {
    final unclassified = [
      for (final operation in operations)
        if (_mutatingMethods.contains(operation.method.toLowerCase()) &&
            _guardedPrefixes.any(operation.path.startsWith) &&
            !protectedRoutes.contains(_key(operation.method, operation.path)) &&
            !_reviewedOpenPaths.contains(operation.path))
          _key(operation.method, operation.path),
    ];
    expect(
      unclassified,
      isEmpty,
      reason:
          'Classify each new plugin or skin mutation route: add it to '
          'extensionManagementRoutes in '
          'lib/src/services/webserver/extension_management_auth.dart (and '
          'declare the extensionsManage security in the spec), or, if it must '
          'stay open, add its path to _reviewedOpenPaths in this test.',
    );
  });
}
