import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/import/parsers/shot_v2_json_parser.dart';
import 'package:reaprime/src/import/parsers/tcl_shot_parser.dart';

const _sampleCount = 600;
const _iterations = 50;

String _legacyShot(int clock) {
  final series = List.generate(
    _sampleCount,
    (i) => (i * 0.137).toStringAsFixed(3),
  ).join(' ');
  final elapsed = List.generate(
    _sampleCount,
    (i) => (i * 0.1).toStringAsFixed(3),
  ).join(' ');
  final stateChange = List.generate(
    _sampleCount,
    (i) => i < _sampleCount ~/ 3 ? '10000000.0' : '-10000000.0',
  ).join(' ');
  final profile = File(
    'test/fixtures/de1app/legacy_with_profile.shot',
  ).readAsStringSync();
  final profileBlock = profile.substring(
    profile.indexOf('profile {'),
    profile.indexOf('settings {'),
  );

  return [
    'clock $clock',
    'espresso_elapsed {$elapsed}',
    'espresso_pressure {$series}',
    'espresso_flow {$series}',
    'espresso_flow_weight {$series}',
    'espresso_weight {$series}',
    'espresso_temperature_basket {$series}',
    'espresso_temperature_mix {$series}',
    'espresso_temperature_goal {$series}',
    'espresso_pressure_goal {$series}',
    'espresso_flow_goal {$series}',
    'espresso_water_dispensed {$series}',
    'espresso_state_change {$stateChange}',
    profileBlock.trimRight(),
    'settings {',
    '\tbean_brand {Benchmark}',
    '\tgrinder_model {Bench Grinder}',
    '\tdrink_weight {36.0}',
    '\tprofile_title {Benchmark}',
    '}',
  ].join('\n');
}

String _v2Shot(int clock) {
  final json =
      jsonDecode(
            File(
              'test/fixtures/de1app/history_v2/20240315T143022.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final series = List.generate(_sampleCount, (i) => i * 0.137);
  json['clock'] = clock;
  json['elapsed'] = List.generate(_sampleCount, (i) => i * 0.1);
  json['pressure'] = {'pressure': series, 'goal': series};
  json['flow'] = {'flow': series, 'goal': series, 'by_weight': series};
  json['temperature'] = {'basket': series, 'mix': series, 'goal': series};
  json['totals'] = {'weight': series, 'water_dispensed': series};
  json['state_change'] = List.generate(
    _sampleCount,
    (i) => i < _sampleCount ~/ 3 ? 10000000.0 : -10000000.0,
  );
  return jsonEncode(json);
}

({double average, double max}) _measure(void Function() parse) {
  parse();
  var total = 0.0;
  var max = 0.0;
  for (var i = 0; i < _iterations; i++) {
    final watch = Stopwatch()..start();
    parse();
    watch.stop();
    final ms = watch.elapsedMicroseconds / 1000;
    total += ms;
    if (ms > max) max = ms;
  }
  return (average: total / _iterations, max: max);
}

void main() {
  group('de1app shot parse cost', () {
    test('records the parse cost of a legacy .shot', () {
      final content = _legacyShot(1699432544);
      final full = _measure(() => TclShotParser.parse(content));
      final metadata = _measure(
        () => TclShotParser.parse(content, metadataOnly: true),
      );

      // ignore: avoid_print
      print(
        'legacy full: avg ${full.average.toStringAsFixed(2)} ms, '
        'max ${full.max.toStringAsFixed(2)} ms; '
        'metadata only: avg ${metadata.average.toStringAsFixed(2)} ms, '
        'max ${metadata.max.toStringAsFixed(2)} ms',
      );

      expect(metadata.average, lessThan(full.average));
      expect(full.average, lessThan(100), reason: 'coarse regression guard');
    });

    test('records the parse cost of a v2 .json', () {
      final content = _v2Shot(1710510622);
      final parsed = _measure(() {
        ShotV2JsonParser.parse(jsonDecode(content) as Map<String, dynamic>);
      });

      // ignore: avoid_print
      print(
        'v2: avg ${parsed.average.toStringAsFixed(2)} ms, '
        'max ${parsed.max.toStringAsFixed(2)} ms',
      );

      expect(parsed.average, lessThan(100), reason: 'coarse regression guard');
    });
  });
}
