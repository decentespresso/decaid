import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/parsers/state_change_frames.dart';

void main() {
  group('framesFromStateChange', () {
    test('returns no frames for an empty series', () {
      expect(framesFromStateChange(const []), isEmpty);
    });

    test('keeps every sample in frame 0 while the sign holds', () {
      expect(
        framesFromStateChange(const [0.0, 10000000.0, 10000000.0]),
        equals([0, 0, 0]),
      );
    });

    test('advances a frame on each sign change', () {
      expect(
        framesFromStateChange(const [
          0.0,
          10000000.0,
          10000000.0,
          -10000000.0,
          -10000000.0,
          10000000.0,
        ]),
        equals([0, 0, 0, 1, 1, 2]),
      );
    });

    test('a leading zero run is not a frame change', () {
      expect(
        framesFromStateChange(const [0.0, 0.0, 10000000.0, -10000000.0]),
        equals([0, 0, 0, 1]),
      );
    });

    test('never decreases', () {
      final frames = framesFromStateChange(const [
        10000000.0,
        -10000000.0,
        10000000.0,
        -10000000.0,
      ]);
      for (var i = 1; i < frames.length; i++) {
        expect(frames[i], greaterThanOrEqualTo(frames[i - 1]));
      }
    });

    test('counts a skipped frame as a single step', () {
      expect(
        framesFromStateChange(const [10000000.0, -10000000.0]),
        equals([0, 1]),
      );
    });
  });
}
