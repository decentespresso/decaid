import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/import/parsers/tcl_shot_parser.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';

/// The DE1 reports at ~5 Hz through de1app and the source shots inherit that
/// irregular cadence. MockDe1 streams at 100 ms, so the recordings are
/// resampled onto a uniform 10 Hz grid here (linear interpolation of the
/// continuous channels; the discrete state/frame carried from the sample at or
/// before each grid point) so replay draws smoothly.
const _resampleMs = 100;

/// Each recording is extrapolated to this length so there is always enough
/// tail for stop-at-weight to reach any realistic target yield, even one past
/// the recorded shot's final weight.
const _targetDurationSeconds = 150.0;

double _lerp(double a, double b, double f) => a + (b - a) * f;

/// Continue a recording to [seconds] by holding its end-state pressure/flow/
/// temperature and keeping weight rising at the final pour rate, so a replayed
/// shot has data for any target weight. Shots already at least this long
/// (e.g. long filter pours) are returned unchanged.
List<ShotSnapshot> _extendTo(List<ShotSnapshot> src, double seconds) {
  if (src.length < 2) return src;
  final origin = src.first.machine.timestamp;
  double elapsedOf(ShotSnapshot s) =>
      s.machine.timestamp.difference(origin).inMicroseconds / 1e6;
  final lastElapsed = elapsedOf(src.last);
  if (lastElapsed >= seconds) return src;

  final tail = src.sublist(src.length >= 20 ? src.length - 20 : 0);
  double avg(double Function(ShotSnapshot) f) =>
      tail.map(f).reduce((a, b) => a + b) / tail.length;
  final heldFlow = avg((s) => s.machine.flow);
  final heldWeightFlow = avg((s) => s.scale?.weightFlow ?? 0);
  var rate = heldWeightFlow > 0.3 ? heldWeightFlow : heldFlow;
  rate = rate.clamp(0.5, 3.0);

  final end = src.last.machine;
  var weight = src.last.scale?.weight ?? 0.0;
  final out = <ShotSnapshot>[...src];
  // The tail is steady-state (constant pressure/flow, linearly rising weight),
  // so 1 Hz keeps the asset small while giving per-second weight resolution —
  // ample for stop-at-weight. The recorded head stays 10 Hz for smooth replay.
  const dt = 1.0;
  for (var t = lastElapsed + dt; t <= seconds + 1e-9; t += dt) {
    weight += rate * dt;
    final ts = origin.add(Duration(microseconds: (t * 1e6).round()));
    out.add(
      ShotSnapshot(
        machine: end.copyWith(timestamp: ts, flow: heldFlow),
        scale: WeightSnapshot(timestamp: ts, weight: weight, weightFlow: rate),
        volume: src.last.volume,
      ),
    );
  }
  return out;
}

List<ShotSnapshot> _resampleTo10Hz(List<ShotSnapshot> src) {
  if (src.length < 2) return src;
  final origin = src.first.machine.timestamp;
  final elapsed = src
      .map((s) => s.machine.timestamp.difference(origin).inMicroseconds / 1e6)
      .toList();
  final lastElapsed = elapsed.last;

  final out = <ShotSnapshot>[];
  var lo = 0;
  for (var k = 0; ; k++) {
    final t = k * _resampleMs / 1000.0;
    if (t > lastElapsed + 1e-9) break;
    while (lo < elapsed.length - 2 && elapsed[lo + 1] < t) {
      lo++;
    }
    final hi = (lo + 1).clamp(0, src.length - 1);
    final span = elapsed[hi] - elapsed[lo];
    final f = span <= 0 ? 0.0 : ((t - elapsed[lo]) / span).clamp(0.0, 1.0);
    final a = src[lo];
    final b = src[hi];
    final ts = origin.add(Duration(microseconds: (t * 1e6).round()));

    final machine = a.machine.copyWith(
      timestamp: ts,
      flow: _lerp(a.machine.flow, b.machine.flow, f),
      pressure: _lerp(a.machine.pressure, b.machine.pressure, f),
      targetFlow: _lerp(a.machine.targetFlow, b.machine.targetFlow, f),
      targetPressure: _lerp(
        a.machine.targetPressure,
        b.machine.targetPressure,
        f,
      ),
      mixTemperature: _lerp(
        a.machine.mixTemperature,
        b.machine.mixTemperature,
        f,
      ),
      groupTemperature: _lerp(
        a.machine.groupTemperature,
        b.machine.groupTemperature,
        f,
      ),
      targetMixTemperature: _lerp(
        a.machine.targetMixTemperature,
        b.machine.targetMixTemperature,
        f,
      ),
      targetGroupTemperature: _lerp(
        a.machine.targetGroupTemperature,
        b.machine.targetGroupTemperature,
        f,
      ),
      steamTemperature: _lerp(
        a.machine.steamTemperature.toDouble(),
        b.machine.steamTemperature.toDouble(),
        f,
      ).round(),
    );

    WeightSnapshot? scale;
    if (a.scale != null && b.scale != null) {
      scale = WeightSnapshot(
        timestamp: ts,
        weight: _lerp(a.scale!.weight, b.scale!.weight, f),
        weightFlow: _lerp(a.scale!.weightFlow, b.scale!.weightFlow, f),
      );
    } else {
      scale = a.scale;
    }

    out.add(ShotSnapshot(machine: machine, scale: scale, volume: a.volume));
  }
  return out;
}

/// Guards — and, on demand, regenerates — the bundled simulator replay corpus.
///
/// Two sources feed `assets/simulations/`, both converted through decaid's own
/// [TclShotParser] and resampled to 10 Hz:
///   - `tool/simulation_sources/*.shot` — de1app sample shots, the generic
///     fallback pool.
///   - `tool/simulation_sources/profiles/*.shot` — real shots pulled from
///     visualizer.coffee, one per bundled profile (filename == the bundled
///     profile's filename stem). These let replay pick a recording made with
///     the currently selected profile. Each carries its `profile_title`.
///
/// The `manifest.json` records the fallback files and the profile-matched
/// files with their profile titles, so [SimulatedShotLibrary] can pick by
/// profile with a random fallback.
///
/// By default this only asserts the committed assets still parse (safe in CI).
/// To rebuild the assets after changing the sources, run:
///   REGEN_SIM_ASSETS=1 flutter test test/tools/generate_simulation_assets_test.dart
void main() {
  const sourceDir = 'tool/simulation_sources';
  const profileDir = 'tool/simulation_sources/profiles';
  const outputDir = 'assets/simulations';
  final regenerate = Platform.environment['REGEN_SIM_ASSETS'] == '1';

  test('bundled simulation assets parse into ShotRecords', () {
    final manifest =
        jsonDecode(File('$outputDir/manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    final files = <String>[
      ...(manifest['fallback'] as List).cast<String>(),
      ...(manifest['profiles'] as List).map((e) => e['file'] as String),
    ];
    expect(files, isNotEmpty);
    for (final file in files) {
      final shot = ShotRecord.fromJson(
        jsonDecode(File('$outputDir/$file').readAsStringSync())
            as Map<String, dynamic>,
      );
      expect(
        shot.measurements,
        isNotEmpty,
        reason: '$file has no measurements',
      );
      // Extended to ~2.5 min with a rising weight tail, so stop-at-weight has
      // enough data for any realistic target yield.
      final m = shot.measurements;
      final duration = m.last.machine.timestamp
          .difference(m.first.machine.timestamp)
          .inSeconds;
      expect(
        duration,
        greaterThanOrEqualTo(149),
        reason: '$file is only ${duration}s long',
      );
      expect(
        m.last.scale?.weight ?? 0,
        greaterThanOrEqualTo(60),
        reason: '$file final weight too low for large targets',
      );
    }
    for (final entry in (manifest['profiles'] as List)) {
      expect((entry['profileTitle'] as String).isNotEmpty, isTrue);
    }
  });

  test(
    'regenerate bundled simulation shots',
    () {
      Directory(outputDir).createSync(recursive: true);

      String convert(File source) {
        final stem = source.uri.pathSegments.last.replaceAll('.shot', '');
        final parsed = TclShotParser.parse(source.readAsStringSync());
        final shot = parsed.shot.copyWith(
          measurements: _extendTo(
            _resampleTo10Hz(parsed.shot.measurements),
            _targetDurationSeconds,
          ),
        );

        final json = shot.toJson();
        json['id'] = 'sim-$stem';
        final workflow = json['workflow'];
        if (workflow is Map) {
          workflow['id'] = 'sim-$stem-workflow';
          // TclShotParser leaves the profile step list empty (it does not
          // reconstruct the advanced_shot frames). Replay drives telemetry from
          // the recorded samples, not the profile, but ShotRecord.fromJson
          // requires a non-empty step list. Inject one representative step built
          // from the recorded frame-0 targets so the asset round-trips.
          final first = shot.measurements.first.machine;
          final durationSeconds =
              shot.measurements.last.machine.timestamp
                  .difference(first.timestamp)
                  .inMilliseconds /
              1000.0;
          final replayStep = ProfileStepPressure(
            name: 'Replay',
            transition: TransitionType.fast,
            volume: 0,
            seconds: durationSeconds,
            temperature: first.targetGroupTemperature > 0
                ? first.targetGroupTemperature
                : 90,
            sensor: TemperatureSensor.coffee,
            pressure: first.targetPressure > 0 ? first.targetPressure : 9,
          );
          final profile = workflow['profile'];
          if (profile is Map) {
            profile['steps'] = [replayStep.toJson()];
          }
        }

        final roundTripped = ShotRecord.fromJson(
          jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
        );
        expect(roundTripped.measurements, isNotEmpty);

        // Compact (unindented) — these are generated, machine-read data files;
        // indentation would roughly double the bundled size.
        File('$outputDir/$stem.json').writeAsStringSync(jsonEncode(json));
        return '$stem.json';
      }

      List<File> shotsIn(String dir) => Directory(dir).existsSync()
          ? (Directory(dir)
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.shot'))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path)))
          : <File>[];

      final fallbackSources = shotsIn(sourceDir);
      expect(fallbackSources, isNotEmpty, reason: 'no fallback .shot sources');
      final fallback = fallbackSources.map(convert).toList();

      // The profile source filename stem matches the bundled profile's
      // filename stem; use that bundled profile's canonical title (not the
      // recorded shot's raw, possibly author-prefixed title) as the match key.
      final profiles = <Map<String, String>>[];
      for (final source in shotsIn(profileDir)) {
        final stem = source.uri.pathSegments.last.replaceAll('.shot', '');
        final bundledProfile = File('assets/defaultProfiles/$stem.json');
        final title = bundledProfile.existsSync()
            ? (jsonDecode(bundledProfile.readAsStringSync())
                      as Map<String, dynamic>)['title']
                  as String
            : TclShotParser.parse(source.readAsStringSync()).shot.workflow.name;
        profiles.add({
          'file': convert(source),
          'profileTitle': title,
          'profileFile': '$stem.json',
        });
      }

      File('$outputDir/manifest.json').writeAsStringSync(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'fallback': fallback, 'profiles': profiles}),
      );
    },
    skip: regenerate ? false : 'set REGEN_SIM_ASSETS=1 to rebuild assets',
  );
}
