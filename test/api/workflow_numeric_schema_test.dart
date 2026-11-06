import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

YamlMap _schema(String name) {
  final spec =
      loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;
  return ((spec['components'] as YamlMap)['schemas'] as YamlMap)[name]
      as YamlMap;
}

YamlMap _properties(String name) => _schema(name)['properties'] as YamlMap;

void main() {
  test(
    'workflow numeric schemas inventory the fields without guessed bounds',
    () {
      expect(
        _properties('SteamSettings').keys,
        containsAll(<String>['targetTemperature', 'duration', 'flow']),
      );
      expect(
        _properties('HotWaterData').keys,
        containsAll(<String>[
          'targetTemperature',
          'duration',
          'volume',
          'flow',
        ]),
      );
      expect(
        _properties('RinseData').keys,
        containsAll(<String>['targetTemperature', 'duration', 'flow']),
      );

      for (final schema in ['SteamSettings', 'HotWaterData', 'RinseData']) {
        for (final property in (_properties(schema)).values) {
          expect(property, isNot(contains('minimum')));
          expect(property, isNot(contains('maximum')));
        }
      }
    },
  );

  test('hot-water flow documents the recommendation separately', () {
    final flow = _properties('HotWaterData')['flow'] as YamlMap;
    expect(flow['description'], contains('consumer skin offers 1–10 ml/s'));
    expect(flow, isNot(contains('minimum')));
    expect(flow, isNot(contains('maximum')));
  });

  test('steam temperature documents its conditional 135 degree semantics', () {
    final temperature =
        _properties('SteamSettings')['targetTemperature'] as YamlMap;
    expect(temperature['description'], contains('135'));
    expect(temperature['description'], contains('disabled'));
  });
}
