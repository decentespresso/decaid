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
      // -1 is UnifiedDe1._refillKit before the connect-time MMR read lands, and
      // the register can carry bits beyond the low one — extra.refillKit masks
      // with 0x01 for exactly that reason. Neither may 500 GET
      // /api/v1/machine/settings/advanced.
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

  test('a refillKitSetting read is documented as a detection result', () {
    final response =
        (_schema('De1AdvancedSettingsResponse')['properties']
                as YamlMap)['refillKitSetting']
            as YamlMap;

    expect(response['description'], contains('detection result'));
  });
}
