// Tests for the derived hydraulic channels R (puckResistanceDerived),
// Z (loadImpedanceDerived) and W (hydraulicPowerDerived) on MachineSnapshot.
// Their measured counterparts live on the Bengle puck-estimator sensor and are
// covered by bengle_puck_estimator_sensor_test.dart.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/machine.dart';

MachineSnapshot _snapshot({required double flow, required double pressure}) =>
    MachineSnapshot(
      timestamp: DateTime.utc(2026, 7, 17, 12, 0, 0),
      state: const MachineStateSnapshot(
        state: MachineState.espresso,
        substate: MachineSubstate.pouring,
      ),
      flow: flow,
      pressure: pressure,
      targetFlow: 2.0,
      targetPressure: 9.0,
      mixTemperature: 92.0,
      groupTemperature: 93.0,
      targetMixTemperature: 93.0,
      targetGroupTemperature: 93.0,
      profileFrame: 1,
      steamTemperature: 140,
    );

void main() {
  group('MachineSnapshot derived channels', () {
    test('computes R, Z and W from pressure and flow', () {
      final snapshot = _snapshot(pressure: 9.0, flow: 2.0);
      expect(snapshot.puckResistanceDerived, closeTo(2.25, 1e-9));
      expect(snapshot.loadImpedanceDerived, closeTo(4.5, 1e-9));
      expect(snapshot.hydraulicPowerDerived, closeTo(1.8, 1e-9));

      final json = snapshot.toJson();
      expect(json['puckResistanceDerived'], closeTo(2.25, 1e-9));
      expect(json['loadImpedanceDerived'], closeTo(4.5, 1e-9));
      expect(json['hydraulicPowerDerived'], closeTo(1.8, 1e-9));
    });

    test('gates on low flow: getters null, keys absent from toJson', () {
      final snapshot = _snapshot(pressure: 9.0, flow: 0.2);
      expect(snapshot.puckResistanceDerived, isNull);
      expect(snapshot.loadImpedanceDerived, isNull);
      expect(snapshot.hydraulicPowerDerived, isNull);

      final json = snapshot.toJson();
      expect(json.containsKey('puckResistanceDerived'), isFalse);
      expect(json.containsKey('loadImpedanceDerived'), isFalse);
      expect(json.containsKey('hydraulicPowerDerived'), isFalse);
    });

    test('gates on low pressure: getters null, keys absent from toJson', () {
      final snapshot = _snapshot(pressure: 0.2, flow: 2.0);
      expect(snapshot.puckResistanceDerived, isNull);
      expect(snapshot.loadImpedanceDerived, isNull);
      expect(snapshot.hydraulicPowerDerived, isNull);

      final json = snapshot.toJson();
      expect(json.containsKey('puckResistanceDerived'), isFalse);
      expect(json.containsKey('loadImpedanceDerived'), isFalse);
      expect(json.containsKey('hydraulicPowerDerived'), isFalse);
    });

    test('zero flow: keys absent and jsonEncode does not throw', () {
      final snapshot = _snapshot(pressure: 9.0, flow: 0.0);
      final json = snapshot.toJson();
      expect(json.containsKey('puckResistanceDerived'), isFalse);
      expect(json.containsKey('loadImpedanceDerived'), isFalse);
      expect(json.containsKey('hydraulicPowerDerived'), isFalse);
      // jsonEncode throws on NaN/Infinity — the gate must keep the
      // division-by-zero results out of the websocket payload entirely.
      expect(() => jsonEncode(snapshot.toJson()), returnsNormally);
    });

    test('round-trip recomputes derived keys from raw fields', () {
      final original = _snapshot(pressure: 9.0, flow: 2.0);
      // Encode/decode simulates a shot stored to history and read back.
      final stored =
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>;
      final restored = MachineSnapshot.fromJson(stored);
      // fromJson never reads the derived keys; toJson recomputes them from
      // the raw pressure/flow fields, so stored history gains the channels
      // on read with zero migration.
      final json = restored.toJson();
      expect(json['puckResistanceDerived'], closeTo(2.25, 1e-9));
      expect(json['loadImpedanceDerived'], closeTo(4.5, 1e-9));
      expect(json['hydraulicPowerDerived'], closeTo(1.8, 1e-9));
    });

    test(
      'boundary: flow and pressure exactly 0.3 are emitted (gate is >=)',
      () {
        final snapshot = _snapshot(pressure: 0.3, flow: 0.3);
        expect(snapshot.puckResistanceDerived, isNotNull);
        expect(snapshot.loadImpedanceDerived, isNotNull);
        expect(snapshot.hydraulicPowerDerived, isNotNull);

        final json = snapshot.toJson();
        expect(json['puckResistanceDerived'], closeTo(0.3 / (0.3 * 0.3), 1e-9));
        expect(json['loadImpedanceDerived'], closeTo(1.0, 1e-9));
        expect(json['hydraulicPowerDerived'], closeTo(0.009, 1e-12));
      },
    );
  });
}
