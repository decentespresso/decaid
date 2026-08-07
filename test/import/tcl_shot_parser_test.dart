import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/parsers/shot_v2_json_parser.dart';
import 'package:reaprime/src/import/parsers/tcl_shot_parser.dart';

void main() {
  group('TclShotParser', () {
    late String fixtureContent;
    late ParsedShot result;

    setUpAll(() {
      final file = File('test/fixtures/de1app/history/20231108T091544.shot');
      fixtureContent = file.readAsStringSync();
      result = TclShotParser.parse(fixtureContent);
    });

    group('timestamp', () {
      test('parses correct timestamp from clock field', () {
        final expected = DateTime.fromMillisecondsSinceEpoch(
          1699432544 * 1000,
          isUtc: true,
        );
        expect(result.shot.timestamp.isAtSameMomentAs(expected), isTrue);
      });
    });

    group('shot ID', () {
      test('shot ID uses de1app-{clock} format', () {
        expect(result.shot.id, equals('de1app-1699432544'));
      });
    });

    group('time-series measurements', () {
      test('produces one snapshot per elapsed entry', () {
        expect(result.shot.measurements.length, equals(9));
      });

      test('first snapshot has pressure 0.0', () {
        expect(result.shot.measurements.first.machine.pressure, equals(0.0));
      });

      test('snapshot at index 4 has correct pressure', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.pressure, closeTo(8.5, 0.001));
      });

      test('snapshot at index 4 has correct flow', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.flow, closeTo(2.6, 0.001));
      });

      test('snapshot at index 4 has correct basket temperature', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.groupTemperature, closeTo(88.0, 0.001));
      });

      test('snapshot at index 4 has correct mix temperature', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.mixTemperature, closeTo(83.0, 0.001));
      });

      test('snapshot at index 4 has correct target pressure', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.targetPressure, closeTo(9.0, 0.001));
      });

      test('snapshot at index 4 has correct weight', () {
        final snap = result.shot.measurements[4];
        expect(snap.scale?.weight, closeTo(1.8, 0.001));
      });

      test('snapshot at index 4 has correct weight flow', () {
        final snap = result.shot.measurements[4];
        expect(snap.scale?.weightFlow, closeTo(2.3, 0.001));
      });

      test('snapshot timestamps are offset from base by elapsed time', () {
        // elapsed[4] = 1.0 second
        final base = result.shot.timestamp;
        final snap4 = result.shot.measurements[4];
        final expectedOffset = Duration(milliseconds: (1.0 * 1000).round());
        final actualDiff = snap4.machine.timestamp.difference(base);
        expect(actualDiff, equals(expectedOffset));
      });
    });

    group('bean metadata', () {
      test('extracts bean brand', () {
        expect(result.beanBrand, equals('Banibeans'));
      });

      test('extracts bean type', () {
        expect(result.beanType, equals('Colombia Huila'));
      });

      test('extracts bean notes', () {
        expect(result.beanNotes, equals('Chocolatey and nutty'));
      });

      test('extracts roast level', () {
        expect(result.roastLevel, equals('Medium'));
      });

      test('extracts roast date', () {
        expect(result.roastDate, equals('2023-10-20'));
      });
    });

    group('grinder metadata', () {
      test('extracts grinder model', () {
        expect(result.grinderModel, equals('Eureka Mignon'));
      });

      test('extracts grinder setting', () {
        expect(result.grinderSetting, equals('2.5'));
      });
    });

    group('shot annotations', () {
      test('extracts actual dose weight', () {
        expect(result.shot.annotations?.actualDoseWeight, closeTo(18.5, 0.001));
      });

      test('extracts actual yield', () {
        expect(result.shot.annotations?.actualYield, closeTo(38.0, 0.001));
      });

      test('extracts TDS', () {
        expect(result.shot.annotations?.drinkTds, closeTo(9.0, 0.001));
      });

      test('extracts EY', () {
        expect(result.shot.annotations?.drinkEy, closeTo(21.0, 0.001));
      });

      test('extracts enjoyment', () {
        expect(result.shot.annotations?.enjoyment, closeTo(80.0, 0.001));
      });

      test('extracts espresso notes', () {
        expect(
          result.shot.annotations?.espressoNotes,
          equals('Balanced, good sweetness'),
        );
      });
    });

    group('profile', () {
      test('creates minimal profile with title from settings', () {
        expect(result.shot.workflow.profile.title, equals('Default'));
      });

      test('profile has empty steps list', () {
        expect(result.shot.workflow.profile.steps, isEmpty);
      });

      test(
        'profile target weight is null when final_desired_shot_weight absent',
        () {
          expect(result.shot.workflow.profile.targetWeight, isNull);
        },
      );

      test(
        'target yield falls back to actual yield when no target available',
        () {
          expect(
            result.shot.workflow.context?.targetYield,
            closeTo(38.0, 0.001),
          );
        },
      );
    });

    group('mismatched array lengths', () {
      test('does not throw when weight array is shorter than elapsed', () {
        final truncated = fixtureContent.replaceFirst(
          'espresso_weight {0.0 0.1 0.3 0.9 1.8 3.2 4.8 6.6 8.5}',
          'espresso_weight {0.0 0.1 0.3 0.9 1.8}',
        );
        expect(() => TclShotParser.parse(truncated), returnsNormally);
      });

      test('truncates snapshots to the shortest array length', () {
        final truncated = fixtureContent.replaceFirst(
          'espresso_weight {0.0 0.1 0.3 0.9 1.8 3.2 4.8 6.6 8.5}',
          'espresso_weight {0.0 0.1 0.3 0.9 1.8}',
        );
        final parsed = TclShotParser.parse(truncated);
        expect(parsed.shot.measurements.length, equals(5));
      });

      test('does not throw when pressure array is shorter than elapsed', () {
        final truncated = fixtureContent.replaceFirst(
          'espresso_pressure {0.0 1.1 3.2 5.8 8.5 9.0 9.0 8.8 8.5}',
          'espresso_pressure {0.0 1.1 3.2}',
        );
        expect(() => TclShotParser.parse(truncated), returnsNormally);
      });
    });

    group('frame reconstruction', () {
      test('all snapshots at frame 0 when profile has no steps', () {
        for (final snap in result.shot.measurements) {
          expect(snap.machine.profileFrame, equals(0));
        }
      });
    });
  });
}
