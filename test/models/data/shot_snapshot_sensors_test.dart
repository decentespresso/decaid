import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/device/machine.dart';

/// Sensor channels must survive the shot-record round trip.
///
/// The estimator moved off MachineSnapshot onto /sensors, and shot records
/// persist MachineSnapshot. Without this field the observer would be live-only
/// and history would silently lose a channel it used to carry.
MachineSnapshot _machine() => MachineSnapshot(
  timestamp: DateTime.utc(2026, 8, 16, 12, 0, 0),
  state: MachineStateSnapshot(
    state: MachineState.espresso,
    substate: MachineSubstate.pouring,
  ),
  flow: 2.0,
  pressure: 9.0,
  targetFlow: 2.0,
  targetPressure: 9.0,
  mixTemperature: 93.0,
  groupTemperature: 92.0,
  targetMixTemperature: 93.0,
  targetGroupTemperature: 92.0,
  profileFrame: 3,
  steamTemperature: 150,
);

void main() {
  group('ShotSnapshot sensor persistence', () {
    test('sensor channels round-trip through JSON', () {
      final snap = ShotSnapshot(
        machine: _machine(),
        sensors: {
          'BengleXYZ-puckestimator': {
            'r1': 4.5,
            'r2': 1.25,
            'compliance': 2.5,
            'hydraulicPowerMeasured': 1.8,
            'collapseEventCount': 3,
          },
        },
      );

      final restored = ShotSnapshot.fromJson(
        jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>,
      );

      final est = restored.sensors!['BengleXYZ-puckestimator']!;
      expect(est['r1'], closeTo(4.5, 1e-9));
      expect(est['hydraulicPowerMeasured'], closeTo(1.8, 1e-9));
      expect(est['collapseEventCount'], 3);
    });

    test('the key is OMITTED when no sensor was attached', () {
      final json = ShotSnapshot(machine: _machine()).toJson();
      // Shot records hold one of these per sample; an empty map on every one
      // would be pure weight.
      expect(json.containsKey('sensors'), isFalse);
    });

    test('an empty sensor map is also omitted', () {
      final json = ShotSnapshot(
        machine: _machine(),
        sensors: const {},
      ).toJson();
      expect(json.containsKey('sensors'), isFalse);
    });

    test('a record written before sensors existed still loads', () {
      // Exactly the shape older builds persisted: no `sensors` key at all.
      final legacy = {
        'machine': _machine().toJson(),
        'scale': null,
        'volume': 36.0,
      };

      final restored = ShotSnapshot.fromJson(legacy);

      expect(restored.sensors, isNull);
      expect(restored.volume, 36.0);
      expect(restored.machine.pressure, 9.0);
    });

    test('multiple sensors are kept separately', () {
      final snap = ShotSnapshot(
        machine: _machine(),
        sensors: {
          'BengleXYZ-puckestimator': {'r1': 4.5},
          'BengleXYZ-milkprobe': {'temperature': 62.0},
        },
      );

      final restored = ShotSnapshot.fromJson(
        jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>,
      );

      expect(restored.sensors, hasLength(2));
      expect(restored.sensors!['BengleXYZ-milkprobe']!['temperature'], 62.0);
    });
  });
}
