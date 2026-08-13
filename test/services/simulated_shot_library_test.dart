import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/simulated_shot_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SimulatedShotLibrary', () {
    test('loads the fallback pool and the profile-matched shots', () async {
      final library = SimulatedShotLibrary();
      await library.ensureLoaded();

      expect(library.isLoaded, isTrue);
      expect(library.isEmpty, isFalse);
      expect(library.fallbackCount, 3);
      expect(library.profileCount, greaterThanOrEqualTo(14));
    });

    test(
      'forProfileTitle returns the shot recorded with that profile',
      () async {
        final library = SimulatedShotLibrary();
        await library.ensureLoaded();

        final shot = library.forProfileTitle('Adaptive v2');
        expect(shot, isNotNull);
        expect(shot!.measurements, isNotEmpty);
        // best_practice.json is the bundled "Adaptive v2" profile.
        expect(shot.id, 'sim-best_practice');
      },
    );

    test('forProfileTitle normalizes case, spacing and punctuation', () async {
      final library = SimulatedShotLibrary();
      await library.ensureLoaded();

      final a = library.forProfileTitle('Adaptive v2');
      expect(library.forProfileTitle('  adaptive   v2 ')?.id, a?.id);
      expect(library.forProfileTitle('ADAPTIVE-V2')?.id, a?.id);
    });

    test(
      'canonical titles are not shadowed by slash-segment aliases',
      () async {
        final library = SimulatedShotLibrary();
        await library.ensureLoaded();

        // "D-Flow / default" registers the alias "default"; it must not shadow
        // the canonical "Default" profile.
        expect(library.forProfileTitle('Default')?.id, 'sim-Default1');
        expect(
          library.forProfileTitle('D-Flow / default')?.id,
          'sim-D-Flow____default',
        );
      },
    );

    test('forProfileTitle is null for an unmatched profile', () async {
      final library = SimulatedShotLibrary();
      await library.ensureLoaded();
      expect(library.forProfileTitle('No Such Profile 999'), isNull);
    });

    test('pickForProfile falls back to a random shot when unmatched', () async {
      final library = SimulatedShotLibrary();
      await library.ensureLoaded();

      final matched = library.pickForProfile('Adaptive v2', Random(1));
      expect(matched!.id, 'sim-best_practice');

      final fallback = library.pickForProfile('No Such Profile 999', Random(1));
      expect(fallback, isNotNull);
      expect(fallback!.measurements, isNotEmpty);
    });

    test('a missing manifest yields an empty library, not a throw', () async {
      final library = SimulatedShotLibrary(
        manifestPath: 'assets/simulations/does-not-exist.json',
      );
      await library.ensureLoaded();

      expect(library.isLoaded, isTrue);
      expect(library.isEmpty, isTrue);
      expect(library.pickForProfile('Adaptive v2', Random(1)), isNull);
    });
  });
}
