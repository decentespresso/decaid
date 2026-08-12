import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test(
    'OpenAPI connect results explicitly allow a null connection error',
    () async {
      final spec =
          loadYaml(await File('assets/api/rest_v1.yml').readAsString())
              as YamlMap;
      final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
      final schema = schemas['DeviceConnectResult'] as YamlMap;

      expect(
        _validates(
          {
            'deviceId': 'scale-1',
            'operation': 'connect',
            'outcome': 'connected',
            'state': 'connected',
            'connectionError': null,
          },
          schema,
          schemas,
        ),
        isTrue,
      );
    },
  );

  test(
    'AsyncAPI connect results allow a JSON Schema null connection error',
    () async {
      final spec = await File('assets/api/websocket_v1.yml').readAsString();

      expect(
        spec,
        contains('''        connectionError:
          oneOf:
            - \$ref: '#/components/schemas/ConnectionError'
            - type: "null"'''),
      );
    },
  );
}

bool _validates(Object? value, YamlMap schema, YamlMap schemas) {
  final ref = schema[r'$ref'];
  if (ref is String) {
    final referencedSchema = schemas[ref.split('/').last] as YamlMap;
    if (!_validates(value, referencedSchema, schemas)) {
      return false;
    }
  }

  if (!_matchesType(value, schema['type'], schema['nullable'] == true)) {
    return false;
  }

  final allowedValues = schema['enum'];
  if (allowedValues is YamlList && !allowedValues.contains(value)) {
    return false;
  }

  final allOf = schema['allOf'];
  if (allOf is YamlList &&
      !allOf.every(
        (candidate) => _validates(value, candidate as YamlMap, schemas),
      )) {
    return false;
  }

  final oneOf = schema['oneOf'];
  if (oneOf is YamlList &&
      oneOf
              .where(
                (candidate) => _validates(value, candidate as YamlMap, schemas),
              )
              .length !=
          1) {
    return false;
  }

  if (value is! Map<Object?, Object?>) {
    return true;
  }

  final required = schema['required'];
  if (required is YamlList && !required.every(value.containsKey)) {
    return false;
  }

  final properties = schema['properties'];
  if (properties is! YamlMap) {
    return true;
  }

  return properties.entries.every(
    (entry) =>
        !value.containsKey(entry.key) ||
        _validates(value[entry.key], entry.value as YamlMap, schemas),
  );
}

bool _matchesType(Object? value, Object? type, bool nullable) {
  if (type == null) {
    return true;
  }

  if (value == null) {
    return nullable || type == 'null';
  }

  return switch (type) {
    'object' => value is Map,
    'string' => value is String,
    _ => false,
  };
}
