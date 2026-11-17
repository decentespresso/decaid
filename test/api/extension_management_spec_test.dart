import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:yaml/yaml.dart';

const _schemeName = 'extensionsManage';

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
