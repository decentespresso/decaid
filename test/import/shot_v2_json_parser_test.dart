import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/parsers/shot_v2_json_parser.dart';

void main() {
  group('ShotV2JsonParser', () {
    late Map<String, dynamic> fixtureJson;
    late ParsedShot result;

    setUpAll(() {
      final file = File('test/fixtures/de1app/history_v2/20240315T143022.json');
      fixtureJson = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      result = ShotV2JsonParser.parse(fixtureJson);
    });

    group('timestamp', () {
      test('parses correct timestamp from clock', () {
        final expected = DateTime.fromMillisecondsSinceEpoch(
          1710510622 * 1000,
          isUtc: true,
        );
        expect(result.shot.timestamp.isAtSameMomentAs(expected), isTrue);
      });
    });

    group('time-series measurements', () {
      test('produces one snapshot per elapsed entry', () {
        expect(result.shot.measurements.length, equals(9));
      });

      test('first snapshot has correct pressure', () {
        final snap = result.shot.measurements.first;
        expect(snap.machine.pressure, equals(0.0));
      });

      test('snapshot at index 4 has correct pressure', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.pressure, closeTo(8.8, 0.001));
      });

      test('snapshot at index 4 has correct flow', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.flow, closeTo(2.8, 0.001));
      });

      test('snapshot at index 4 has correct basket temperature', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.groupTemperature, closeTo(89.0, 0.001));
      });

      test('snapshot at index 4 has correct mix temperature', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.mixTemperature, closeTo(85.0, 0.001));
      });

      test('snapshot at index 4 has correct target pressure', () {
        final snap = result.shot.measurements[4];
        expect(snap.machine.targetPressure, closeTo(9.0, 0.001));
      });

      test('snapshot at index 4 has correct weight', () {
        final snap = result.shot.measurements[4];
        expect(snap.scale?.weight, closeTo(2.0, 0.001));
      });

      test('snapshot at index 4 has correct weight flow', () {
        final snap = result.shot.measurements[4];
        expect(snap.scale?.weightFlow, closeTo(2.5, 0.001));
      });

      test('snapshot timestamps are offset from base by elapsed time', () {
        final base = result.shot.timestamp;
        final snap4 = result.shot.measurements[4];
        final expectedOffset = Duration(milliseconds: (1.0 * 1000).round());
        final actualDiff = snap4.machine.timestamp.difference(base);
        expect(actualDiff, equals(expectedOffset));
      });
    });

    group('embedded profile', () {
      test('extracts profile title', () {
        expect(result.shot.workflow.profile.title, equals('Best Practice'));
      });

      test('extracts correct step count', () {
        expect(result.shot.workflow.profile.steps.length, equals(2));
      });

      test('first step name is preinfusion', () {
        expect(
          result.shot.workflow.profile.steps.first.name,
          equals('preinfusion'),
        );
      });
    });

    group('bean metadata', () {
      test('extracts bean brand', () {
        expect(result.beanBrand, equals('Banibeans'));
      });

      test('extracts bean type', () {
        expect(result.beanType, equals('Ethiopia Yirgacheffe'));
      });

      test('extracts bean notes', () {
        expect(result.beanNotes, equals('Fruity and floral'));
      });

      test('extracts roast level', () {
        expect(result.roastLevel, equals('Light'));
      });

      test('extracts roast date', () {
        expect(result.roastDate, equals('2024-03-01'));
      });
    });

    group('grinder metadata', () {
      test('extracts grinder model', () {
        expect(result.grinderModel, equals('Niche Zero'));
      });

      test('extracts grinder setting', () {
        expect(result.grinderSetting, equals('15'));
      });
    });

    group('shot annotations', () {
      test('extracts actual dose weight', () {
        expect(result.shot.annotations?.actualDoseWeight, closeTo(18.0, 0.001));
      });

      test('extracts actual yield', () {
        expect(result.shot.annotations?.actualYield, closeTo(36.0, 0.001));
      });

      test('extracts TDS', () {
        expect(result.shot.annotations?.drinkTds, closeTo(8.5, 0.001));
      });

      test('extracts EY', () {
        expect(result.shot.annotations?.drinkEy, closeTo(20.5, 0.001));
      });

      test('extracts enjoyment', () {
        expect(result.shot.annotations?.enjoyment, closeTo(75.0, 0.001));
      });

      test('extracts espresso notes', () {
        expect(
          result.shot.annotations?.espressoNotes,
          equals('Good body, slight sourness'),
        );
      });
    });

    group('workflow context', () {
      test('context is not null', () {
        expect(result.shot.workflow.context, isNotNull);
      });

      test('extracts target dose weight into context', () {
        expect(
          result.shot.workflow.context?.targetDoseWeight,
          closeTo(18.0, 0.001),
        );
      });

      test('extracts target yield into context', () {
        expect(result.shot.workflow.context?.targetYield, closeTo(36.0, 0.001));
      });

      test('extracts grinder model into context', () {
        expect(
          result.shot.workflow.context?.grinderModel,
          equals('Niche Zero'),
        );
      });

      test('extracts grinder setting into context', () {
        expect(result.shot.workflow.context?.grinderSetting, equals('15'));
      });

      test('extracts coffee name (beanType) into context', () {
        expect(
          result.shot.workflow.context?.coffeeName,
          equals('Ethiopia Yirgacheffe'),
        );
      });

      test('extracts coffee roaster (beanBrand) into context', () {
        expect(
          result.shot.workflow.context?.coffeeRoaster,
          equals('Banibeans'),
        );
      });

      test('extracts barista name from settings', () {
        expect(result.shot.workflow.context?.baristaName, equals('Test User'));
      });

      test('extracts drinker name from settings', () {
        expect(result.shot.workflow.context?.drinkerName, equals('Guest'));
      });
    });

    group('shot ID', () {
      test('shot ID uses de1app-{clock} format', () {
        expect(result.shot.id, equals('de1app-1710510622'));
      });
    });

    group('fallback to settings when meta absent', () {
      test('parses dose from settings when meta is missing', () {
        final noMeta = Map<String, dynamic>.from(fixtureJson)..remove('meta');
        final parsed = ShotV2JsonParser.parse(noMeta);
        expect(parsed.shot.annotations?.actualDoseWeight, closeTo(18.0, 0.001));
      });

      test('parses bean brand from settings when meta is missing', () {
        final noMeta = Map<String, dynamic>.from(fixtureJson)..remove('meta');
        final parsed = ShotV2JsonParser.parse(noMeta);
        expect(parsed.beanBrand, equals('Banibeans'));
      });
    });

    group('missing profile key', () {
      test('does not throw when profile key is absent', () {
        final noProfile = Map<String, dynamic>.from(fixtureJson)
          ..remove('profile');
        expect(() => ShotV2JsonParser.parse(noProfile), returnsNormally);
      });

      test(
        'falls back to profile title from settings when profile key is absent',
        () {
          final noProfile = Map<String, dynamic>.from(fixtureJson)
            ..remove('profile');
          final parsed = ShotV2JsonParser.parse(noProfile);
          expect(parsed.shot.workflow.profile.title, equals('Best Practice'));
        },
      );

      test('fallback profile has empty steps list', () {
        final noProfile = Map<String, dynamic>.from(fixtureJson)
          ..remove('profile');
        final parsed = ShotV2JsonParser.parse(noProfile);
        expect(parsed.shot.workflow.profile.steps, isEmpty);
      });
    });

    group('mismatched array lengths', () {
      test('does not throw when weight array is shorter than elapsed', () {
        final truncated = Map<String, dynamic>.from(fixtureJson);
        final totals = Map<String, dynamic>.from(
          fixtureJson['totals'] as Map<String, dynamic>,
        );
        totals['weight'] = [0.0, 0.1, 0.4, 1.0, 2.0, 3.5];
        totals['water_dispensed'] = [0.0, 0.2, 0.5, 1.2, 2.2, 3.8];
        truncated['totals'] = totals;
        expect(() => ShotV2JsonParser.parse(truncated), returnsNormally);
      });

      test('truncates snapshots to the shortest array length', () {
        final truncated = Map<String, dynamic>.from(fixtureJson);
        final totals = Map<String, dynamic>.from(
          fixtureJson['totals'] as Map<String, dynamic>,
        );
        totals['weight'] = [0.0, 0.1, 0.4, 1.0, 2.0, 3.5];
        totals['water_dispensed'] = [0.0, 0.2, 0.5, 1.2, 2.2, 3.8];
        truncated['totals'] = totals;
        final parsed = ShotV2JsonParser.parse(truncated);
        expect(parsed.shot.measurements.length, equals(6));
      });

      test('does not throw when flow array is shorter than elapsed', () {
        final truncated = Map<String, dynamic>.from(fixtureJson);
        final flow = Map<String, dynamic>.from(
          fixtureJson['flow'] as Map<String, dynamic>,
        );
        flow['flow'] = [0.0, 0.5, 1.2, 2.1];
        truncated['flow'] = flow;
        expect(() => ShotV2JsonParser.parse(truncated), returnsNormally);
      });
    });

    group('string-typed clock field', () {
      test('parses clock when stored as string (real de1app behavior)', () {
        final stringClock = Map<String, dynamic>.from(fixtureJson);
        stringClock['clock'] = '1710510622';
        final parsed = ShotV2JsonParser.parse(stringClock);
        final expected = DateTime.fromMillisecondsSinceEpoch(
          1710510622 * 1000,
          isUtc: true,
        );
        expect(parsed.shot.timestamp.isAtSameMomentAs(expected), isTrue);
      });

      test('throws FormatException for non-numeric clock', () {
        final badClock = Map<String, dynamic>.from(fixtureJson);
        badClock['clock'] = 'not-a-number';
        expect(
          () => ShotV2JsonParser.parse(badClock),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('missing time-series data', () {
      test('returns empty measurements when elapsed is missing', () {
        final noElapsed = Map<String, dynamic>.from(fixtureJson);
        noElapsed.remove('elapsed');
        final parsed = ShotV2JsonParser.parse(noElapsed);
        expect(parsed.shot.measurements, isEmpty);
      });

      test('produces null scale when totals is missing', () {
        final noTotals = Map<String, dynamic>.from(fixtureJson);
        noTotals.remove('totals');
        final parsed = ShotV2JsonParser.parse(noTotals);
        expect(parsed.shot.measurements, isNotEmpty);
        expect(parsed.shot.measurements.first.scale, isNull);
      });
    });

    group('frame reconstruction', () {
      test('all snapshots in frame 0 for short shot', () {
        for (final snap in result.shot.measurements) {
          expect(snap.machine.profileFrame, equals(0));
        }
      });

      test('crosses frame boundary with multi-step profile', () {
        final shot = Map<String, dynamic>.from(fixtureJson);
        shot['elapsed'] = [0.0, 5.0, 10.5, 15.0, 30.0, 50.0];
        shot['profile'] = {
          'version': '2',
          'title': 'Test',
          'notes': '',
          'author': '',
          'beverage_type': 'espresso',
          'steps': [
            {
              'name': 'preinfusion',
              'seconds': '10',
              'pump': 'pressure',
              'temperature': '93',
              'sensor': 'coffee',
              'transition': 'fast',
              'volume': '0',
              'weight': '0',
              'pressure': '1',
            },
            {
              'name': 'hold',
              'seconds': '30',
              'pump': 'pressure',
              'temperature': '93',
              'sensor': 'coffee',
              'transition': 'smooth',
              'volume': '0',
              'weight': '0',
              'pressure': '9',
            },
            {
              'name': 'decline',
              'seconds': '20',
              'pump': 'pressure',
              'temperature': '93',
              'sensor': 'coffee',
              'transition': 'smooth',
              'volume': '0',
              'weight': '0',
              'pressure': '4',
            },
          ],
          'target_volume': 0,
          'target_weight': 36,
          'target_volume_count_start': '1',
          'tank_temperature': 0,
        };
        shot['pressure'] = {
          'pressure': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
          'goal': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
        };
        shot['flow'] = {
          'flow': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
          'by_weight': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
          'goal': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
        };
        shot['temperature'] = {
          'basket': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
          'mix': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
          'goal': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
        };
        shot['totals'] = {
          'weight': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
          'water_dispensed': [0.0, 1.0, 2.0, 3.0, 4.0, 5.0],
        };

        final parsed = ShotV2JsonParser.parse(shot);
        final frames = parsed.shot.measurements
            .map((s) => s.machine.profileFrame)
            .toList();

        expect(frames, equals([0, 0, 1, 1, 1, 2]));
      });

      test('profile with no steps returns frame 0 for all snapshots', () {
        final noSteps = Map<String, dynamic>.from(fixtureJson)
          ..remove('profile');
        final parsed = ShotV2JsonParser.parse(noSteps);
        for (final snap in parsed.shot.measurements) {
          expect(snap.machine.profileFrame, equals(0));
        }
      });
    });
  });
}
