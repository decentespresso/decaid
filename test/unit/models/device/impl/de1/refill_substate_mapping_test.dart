import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.utils.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:yaml/yaml.dart';

MachineSnapshot _snapshotWith(MachineState state, MachineSubstate substate) {
  return MachineSnapshot(
    timestamp: DateTime.utc(2026, 9, 9),
    state: MachineStateSnapshot(state: state, substate: substate),
    flow: 0,
    pressure: 0,
    targetFlow: 0,
    targetPressure: 0,
    mixTemperature: 0,
    groupTemperature: 0,
    targetMixTemperature: 0,
    targetGroupTemperature: 0,
    profileFrame: 0,
    steamTemperature: 0,
  );
}

List<String> _substates(String specPath) {
  final spec = loadYaml(File(specPath).readAsStringSync()) as YamlMap;
  final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
  final values = (schemas['MachineSubstate'] as YamlMap)['enum'] as YamlList;
  return values.map((value) => value.toString()).toList();
}

void main() {
  group('refill substate mapping', () {
    test('decodes refill stopped and maps the two-dimensional state pair', () {
      final state = De1StateEnum.fromHexValue(0x11);
      final substate = De1SubState.fromHexValue(0x11);

      expect(state, De1StateEnum.refill);
      expect(substate, De1SubState.refillStopped);
      expect(mapDe1ToMachineState(state), MachineState.needsWater);
      expect(
        mapDe1SubToMachineSubstate(substate!),
        MachineSubstate.refillStopped,
      );
    });

    test('refill with no state remains needsWater and idle', () {
      final state = De1StateEnum.fromHexValue(0x11);
      final substate = De1SubState.fromHexValue(0x00);

      expect(mapDe1ToMachineState(state), MachineState.needsWater);
      expect(substate, De1SubState.noState);
      expect(mapDe1SubToMachineSubstate(substate!), MachineSubstate.idle);
    });

    test('user absence remains idle', () {
      expect(
        mapDe1SubToMachineSubstate(De1SubState.userNotPresent),
        MachineSubstate.idle,
      );
    });

    test('unrelated raw mappings remain unchanged', () {
      expect(
        mapDe1ToMachineState(De1StateEnum.fromHexValue(0x05)),
        MachineState.steam,
      );
      expect(
        mapDe1SubToMachineSubstate(De1SubState.fromHexValue(0x12)!),
        MachineSubstate.pausedSteam,
      );
      expect(
        mapDe1SubToMachineSubstate(De1SubState.fromHexValue(0x14)!),
        MachineSubstate.puffing,
      );
    });
  });

  group('refill snapshot contract', () {
    test('round-trips the needsWater refillStopped snapshot', () {
      final snapshot = _snapshotWith(
        MachineState.needsWater,
        MachineSubstate.refillStopped,
      );
      final json = snapshot.toJson();
      final restored = MachineSnapshot.fromJson(json);

      expect((json['state'] as Map)['state'], 'needsWater');
      expect((json['state'] as Map)['substate'], 'refillStopped');
      expect(restored.state.state, MachineState.needsWater);
      expect(restored.state.substate, MachineSubstate.refillStopped);
    });

    test('reads literal old idle snapshots', () {
      final restored = MachineSnapshot.fromJson({
        'timestamp': '2026-09-09T00:00:00.000Z',
        'state': {'state': 'needsWater', 'substate': 'idle'},
        'flow': 0.0,
        'pressure': 0.0,
        'targetFlow': 0.0,
        'targetPressure': 0.0,
        'mixTemperature': 0.0,
        'groupTemperature': 0.0,
        'targetMixTemperature': 0.0,
        'targetGroupTemperature': 0.0,
        'profileFrame': 0,
        'steamTemperature': 0,
      });

      expect(restored.state.state, MachineState.needsWater);
      expect(restored.state.substate, MachineSubstate.idle);
    });

    test('both API specs publish refillStopped', () {
      expect(_substates('assets/api/rest_v1.yml'), contains('refillStopped'));
      expect(
        _substates('assets/api/websocket_v1.yml'),
        contains('refillStopped'),
      );
    });
  });
}
