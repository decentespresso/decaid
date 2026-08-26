import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:yaml/yaml.dart';

YamlMap _schema(String name) {
  final spec =
      loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;
  return ((spec['components'] as YamlMap)['schemas'] as YamlMap)[name]
      as YamlMap;
}

void main() {
  group('De1RefillKitSettings.fromInt', () {
    test('maps the three register values the machine defines', () {
      expect(De1RefillKitSettings.fromInt(0), De1RefillKitSettings.forceOff);
      expect(De1RefillKitSettings.fromInt(1), De1RefillKitSettings.forceOn);
      expect(De1RefillKitSettings.fromInt(2), De1RefillKitSettings.auto);
    });

    test('falls back to auto instead of throwing on an unknown value', () {
      // Configuration parsing only: the REST layer rejects an out-of-range
      // refillKitSetting with 400 before this is reached, and detection never
      // goes through here. The fallback keeps a stray value from throwing.
      for (final raw in [-1, 3, 0x81, 255]) {
        expect(
          De1RefillKitSettings.fromInt(raw),
          De1RefillKitSettings.auto,
          reason: 'register value $raw must not throw',
        );
      }
    });
  });

  test('MachineInfo.extra documents the refill-kit detection flag', () {
    final extra =
        (_schema('MachineInfo')['properties'] as YamlMap)['extra'] as YamlMap;
    final properties = extra['properties'] as YamlMap;

    expect(properties.keys, containsAll(<String>['refillKit', 'voltage']));
    expect((properties['refillKit'] as YamlMap)['type'], 'boolean');
    expect(
      extra['additionalProperties'],
      isTrue,
      reason: 'extra stays open to keys this spec does not list',
    );
  });

  test('refillKitSetting is documented as an override, not a detection', () {
    final response =
        (_schema('De1AdvancedSettingsResponse')['properties']
                as YamlMap)['refillKitSetting']
            as YamlMap;
    final description = response['description'] as String;

    expect(description, contains('override'));
    expect(description, contains('not a detection result'));
    expect(
      description,
      contains('MachineInfo.extra.refillKit'),
      reason: 'a reader sent here for detection needs the field name',
    );
  });

  test('MachineInfo.extra.refillKit is documented as detection', () {
    final refillKit =
        (((_schema('MachineInfo')['properties'] as YamlMap)['extra']
                    as YamlMap)['properties']
                as YamlMap)['refillKit']
            as YamlMap;

    expect(refillKit['description'], contains('detected'));
    expect(
      refillKit['description'],
      contains('writing `refillKitSetting` does not change it'),
    );
  });
}
