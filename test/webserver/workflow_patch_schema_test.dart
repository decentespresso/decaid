import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

YamlMap _schema(String name) {
  final spec =
      loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;
  return ((spec['components'] as YamlMap)['schemas'] as YamlMap)[name]
      as YamlMap;
}

YamlMap _properties(String schema) => _schema(schema)['properties'] as YamlMap;

Set<String> _fieldNames(String schema) =>
    _properties(schema).keys.cast<String>().toSet();

void main() {
  test('a workflow PUT body validates context as WorkflowContextPatch', () {
    expect(
      (_properties('WorkflowPatch')['context'] as YamlMap)[r'$ref'],
      '#/components/schemas/WorkflowContextPatch',
      reason: 'the PUT rule has to be in the schema, not only in prose',
    );
  });

  test('a returned workflow keeps the fully nullable WorkflowContext', () {
    expect(
      (_properties('WorkflowRequest')['context'] as YamlMap)[r'$ref'],
      '#/components/schemas/WorkflowContext',
    );
    expect(
      (_properties('WorkflowContext')['targetYield'] as YamlMap)['nullable'],
      isTrue,
      reason: 'a stored or returned shot legitimately has no target yield',
    );
  });

  test('WorkflowContextPatch carries every WorkflowContext field', () {
    expect(
      _fieldNames('WorkflowContextPatch'),
      equals(_fieldNames('WorkflowContext')),
      reason: 'the patch schema is hand-maintained and must not drift',
    );
  });

  test('grinderRpm is a nullable non-negative integer', () {
    for (final schema in ['WorkflowContext', 'WorkflowContextPatch']) {
      final rpm = _properties(schema)['grinderRpm'] as YamlMap;
      expect(rpm['type'], 'integer');
      expect(rpm['nullable'], isTrue);
      expect(rpm['minimum'], 0);
    }
  });

  test('only targetYield loses its nullability on a PUT', () {
    final patch = _properties('WorkflowContextPatch');

    expect(
      (patch['targetYield'] as YamlMap)['nullable'],
      isNot(true),
      reason: 'the handler refuses an explicit null targetYield with 400',
    );

    for (final field in _fieldNames('WorkflowContextPatch')) {
      if (field == 'targetYield') continue;
      expect(
        (patch[field] as YamlMap)['nullable'],
        isTrue,
        reason: '$field is cleared by an explicit null, so it stays nullable',
      );
    }
  });
}
