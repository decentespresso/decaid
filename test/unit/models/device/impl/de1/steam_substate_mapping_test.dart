import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.utils.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:yaml/yaml.dart';

MachineSnapshot _snapshotWith(MachineSubstate substate) {
  return MachineSnapshot(
    timestamp: DateTime.utc(2026, 9, 9),
    state: MachineStateSnapshot(state: MachineState.steam, substate: substate),
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

List<String> _restSubstates() {
  final spec =
      loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;
  final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
  final values = (schemas['MachineSubstate'] as YamlMap)['enum'] as YamlList;
  return values.map((v) => v.toString()).toList();
}

List<String> _websocketSubstates() {
  final spec =
      loadYaml(File('assets/api/websocket_v1.yml').readAsStringSync())
          as YamlMap;
  final schemas = (spec['components'] as YamlMap)['schemas'] as YamlMap;
  final values = (schemas['MachineSubstate'] as YamlMap)['enum'] as YamlList;
  return values.map((v) => v.toString()).toList();
}

void main() {
  group('steam substate mapping', () {
    test('pausedSteam maps to MachineSubstate.pausedSteam', () {
      expect(
        mapDe1SubToMachineSubstate(De1SubState.pausedSteam),
        MachineSubstate.pausedSteam,
      );
    });

    test('puffing maps to MachineSubstate.puffing', () {
      expect(
        mapDe1SubToMachineSubstate(De1SubState.puffing),
        MachineSubstate.puffing,
      );
    });

    test('the substates that share the old mapping still report idle', () {
      for (final sub in [De1SubState.noState, De1SubState.userNotPresent]) {
        expect(
          mapDe1SubToMachineSubstate(sub),
          MachineSubstate.idle,
          reason: '${sub.name} must still map to idle',
        );
      }
    });
  });

  group('machine snapshot contract', () {
    test('serializes each new substate under its own name', () {
      for (final substate in [
        MachineSubstate.pausedSteam,
        MachineSubstate.puffing,
      ]) {
        final json = _snapshotWith(substate).toJson();
        expect((json['state'] as Map)['substate'], substate.name);
      }
    });

    test('round-trips each new substate through fromJson', () {
      for (final substate in [
        MachineSubstate.pausedSteam,
        MachineSubstate.puffing,
      ]) {
        final restored = MachineSnapshot.fromJson(
          _snapshotWith(substate).toJson(),
        );
        expect(restored.state.substate, substate);
      }
    });

    test('both specs publish the new substates', () {
      for (final name in ['pausedSteam', 'puffing']) {
        expect(
          _restSubstates(),
          contains(name),
          reason: 'rest_v1.yml MachineSubstate must publish $name',
        );
        expect(
          _websocketSubstates(),
          contains(name),
          reason: 'websocket_v1.yml MachineSubstate must publish $name',
        );
      }
    });
  });
}
