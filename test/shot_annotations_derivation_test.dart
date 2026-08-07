import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/device/machine.dart';

/// A single throwaway machine snapshot — the derivation only reads scale
/// weights, so every measurement can share one.
final _machine = MachineSnapshot(
  timestamp: DateTime(2026, 6, 5),
  state: const MachineStateSnapshot(
    state: MachineState.espresso,
    substate: MachineSubstate.pouring,
  ),
  flow: 2.0,
  pressure: 9.0,
  targetFlow: 2.0,
  targetPressure: 9.0,
  mixTemperature: 92.0,
  groupTemperature: 92.0,
  targetMixTemperature: 92.0,
  targetGroupTemperature: 92.0,
  profileFrame: 0,
  steamTemperature: 0,
);

ShotSnapshot _snap(double? weight) => ShotSnapshot(
  machine: _machine,
  scale: weight == null
      ? null
      : WeightSnapshot(
          timestamp: DateTime(2026, 6, 5),
          weight: weight,
          weightFlow: 0.0,
        ),
);

List<ShotSnapshot> _trace(List<double?> weights) => weights.map(_snap).toList();

void main() {
  group('ShotAnnotations.finalScaleWeight', () {
    test('returns the settled final reading of a normal pour', () {
      final m = _trace([0.0, 0.0, 5.2, 18.4, 33.9, 39.8, 40.0, 40.1]);
      expect(ShotAnnotations.finalScaleWeight(m), 40.1);
    });

    test('ignores the portafilter placement spike at the start', () {
      final m = _trace([286.7, 0.0, 0.0, 12.0, 40.0, 40.1, 40.0]);
      expect(ShotAnnotations.finalScaleWeight(m), 40.0);
    });

    test('skips trailing zero / dropout samples', () {
      final m = _trace([0.0, 20.0, 40.0, 0.0, 0.0]);
      expect(ShotAnnotations.finalScaleWeight(m), 40.0);
    });

    test('rounds to 0.1 g like de1app', () {
      expect(ShotAnnotations.finalScaleWeight(_trace([89.97])), 90.0);
    });

    test('is null when no scale was recording', () {
      expect(
        ShotAnnotations.finalScaleWeight(_trace([null, null, null])),
        isNull,
      );
    });

    test('is null for an empty measurement list', () {
      expect(ShotAnnotations.finalScaleWeight([]), isNull);
    });
  });

  group('ShotAnnotations.deriveForFinishedShot', () {
    test('fills actual yield from the scale and actual dose from target', () {
      final ann = ShotAnnotations.deriveForFinishedShot(
        measurements: _trace([0.0, 18.0, 36.0, 40.1]),
        targetDoseWeight: 18.0,
      );
      expect(ann, isNotNull);
      expect(ann!.actualYield, 40.1);
      expect(ann.actualDoseWeight, 18.0);
      expect(ann.drinkTds, isNull);
      expect(ann.drinkEy, isNull);
      expect(ann.enjoyment, isNull);
      expect(ann.espressoNotes, isNull);
    });

    test('prefers a trusted yield latched by the shot sequencer', () {
      final ann = ShotAnnotations.deriveForFinishedShot(
        measurements: _trace([0.0, 18.0, 36.0, 2.0]),
        targetDoseWeight: 18.0,
        preferredYield: 36.4,
      );
      expect(ann, isNotNull);
      expect(ann!.actualYield, 36.4);
      expect(ann.actualDoseWeight, 18.0);
    });

    test('still records dose when no scale is connected', () {
      final ann = ShotAnnotations.deriveForFinishedShot(
        measurements: _trace([null, null]),
        targetDoseWeight: 19.0,
      );
      expect(ann, isNotNull);
      expect(ann!.actualDoseWeight, 19.0);
      expect(ann.actualYield, isNull);
    });

    test('still records yield when no target dose is set', () {
      final ann = ShotAnnotations.deriveForFinishedShot(
        measurements: _trace([0.0, 20.0, 38.0]),
        targetDoseWeight: null,
      );
      expect(ann, isNotNull);
      expect(ann!.actualYield, 38.0);
      expect(ann.actualDoseWeight, isNull);
    });

    test('treats a zero target dose as unset', () {
      final ann = ShotAnnotations.deriveForFinishedShot(
        measurements: _trace([0.0, 20.0, 38.0]),
        targetDoseWeight: 0.0,
      );
      expect(ann, isNotNull);
      expect(ann!.actualDoseWeight, isNull);
      expect(ann.actualYield, 38.0);
    });

    test('returns null when there is nothing to derive', () {
      final ann = ShotAnnotations.deriveForFinishedShot(
        measurements: _trace([null, null]),
        targetDoseWeight: 0.0,
      );
      expect(ann, isNull);
    });
  });
}
