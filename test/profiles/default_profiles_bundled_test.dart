import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart'
    show
        BeverageType,
        ExitCondition,
        ExitType,
        Profile,
        ProfileStepFlow,
        ProfileStepPressure,
        TransitionType;
import 'package:reaprime/src/models/data/profile_hash.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> files;
  final profiles = <String, Profile>{};

  setUpAll(() async {
    final manifest = jsonDecode(
      await rootBundle.loadString('assets/defaultProfiles/manifest.json'),
    ) as Map<String, dynamic>;
    files = (manifest['profiles'] as List).cast<String>();
    for (final f in files) {
      final json = jsonDecode(
        await rootBundle.loadString('assets/defaultProfiles/$f'),
      ) as Map<String, dynamic>;
      profiles[f] = Profile.fromJson(json);
    }
  });

  test('manifest is non-empty and every entry parses', () {
    expect(files, isNotEmpty);
    expect(profiles.length, files.length);
  });

  test('notes carry no Visualizer/import boilerplate', () {
    for (final entry in profiles.entries) {
      final notes = entry.value.notes;
      expect(notes.contains('Downloaded from'), isFalse, reason: entry.key);
      expect(
        notes.toLowerCase().contains('visualizer'),
        isFalse,
        reason: entry.key,
      );
    }
  });

  test('titles carry no leftover category prefix', () {
    final prefix = RegExp(r'^(Visualizer|Espresso)/');
    for (final entry in profiles.entries) {
      expect(
        prefix.hasMatch(entry.value.title),
        isFalse,
        reason: '${entry.value.title} (${entry.key})',
      );
    }
  });

  test('no two profiles share execution content (no hash collisions)', () {
    final byHash = <String, String>{};
    for (final entry in profiles.entries) {
      final hash = ProfileHash.calculateProfileHash(entry.value);
      final clash = byHash[hash];
      expect(
        clash,
        isNull,
        reason: 'identical content: ${entry.key} == $clash',
      );
      byHash[hash] = entry.key;
    }
  });

  test('A-Flow Pause after 2nd Fill has a 15s timeout, not zero', () {
    // Issue #580: on DE1, a zero-duration frame with a machine-side exit
    // times out on the next control tick instead of waiting for the exit.
    // The official A-Flow generator assigns this Pause a 15s timeout.
    const expected = 15.0;
    final checked = <String>[];
    for (final entry in profiles.entries) {
      final steps = entry.value.steps;
      for (var i = 1; i < steps.length - 1; i++) {
        final prev = steps[i - 1];
        final step = steps[i];
        final next = steps[i + 1];
        if (prev.name != '2nd Fill' ||
            step.name != 'Pause' ||
            next.name != 'Pressure Up') {
          continue;
        }
        checked.add(entry.key);
        expect(
          step.exit,
          isNotNull,
          reason: '${entry.key}: Pause must keep its machine-side exit',
        );
        expect(
          step.seconds,
          expected,
          reason: '${entry.key}: Pause must cap at 15s instead of timing out',
        );
        expect(
          step.exit!.type,
          ExitType.flow,
          reason: '${entry.key}: Pause exit must remain flow-under',
        );
        expect(
          step.exit!.condition,
          ExitCondition.under,
          reason: '${entry.key}: Pause exit must remain flow-under',
        );
        expect(
          step.exit!.value,
          1.0,
          reason: '${entry.key}: Pause exit must remain flow < 1.0',
        );
      }
    }
    expect(checked, isNotEmpty, reason: 'expected at least one A-Flow variant');
    expect(
      checked,
      containsAll(<String>[
        'A-Flow____default-dark.json',
        'A-Flow____default-light.json',
        'A-Flow____default-like-dflow.json',
        'A-Flow____default-medium.json',
        'A-Flow____default-very-dark.json',
      ]),
    );
  });

  test('the four Baseline variants are present with canonical titles', () {
    final titles = profiles.values.map((p) => p.title).toSet();
    expect(
      titles,
      containsAll(<String>[
        'Baseline • Ultra Low Contact',
        'Baseline • Low Contact • 4 Bar',
        'Baseline • Medium Contact • 6 Bar',
        'Baseline • High Contact • 8 Bar',
      ]),
    );
  });

  // Ported from decentespresso/de1app, branch stable, revision
  // ea2d30183954551e387841e88e3b254660d5e03a (de1plus/profiles/*.tcl).
  // The execution hash covers version, beverage type, tank temperature, the
  // volume/weight targets and every field of every step. A failure means a
  // ported profile drifted from its de1app source: re-check against that
  // revision before touching the expected value.
  const ported = <String, (BeverageType, String)>{
    'Best overall pressure profile': (
      BeverageType.espresso,
      'profile:f1b836e535b0b57f44a2',
    ),
    'E61 espresso machine': (
      BeverageType.espresso,
      'profile:28d47321846585be3d40',
    ),
    'E61 classic gently up to 10 bar': (
      BeverageType.espresso,
      'profile:9e902a31f13fb8ea2c8e',
    ),
    'E61 rocketing up to 10 bar': (
      BeverageType.espresso,
      'profile:242a62e1111b4a1bc47e',
    ),
    'E61 with fast preinfusion to 9 bar': (
      BeverageType.espresso,
      'profile:badeb80f41ebf99c93e3',
    ),
    'Gentle flat 2.5 ml per second': (
      BeverageType.espresso,
      'profile:0ef8e395628904bd569a',
    ),
    'Gentle preinfusion flow profile': (
      BeverageType.espresso,
      'profile:676679ab3b3a0aff25c6',
    ),
    'Gentler but still traditional 8.4 bar': (
      BeverageType.espresso,
      'profile:a258c0df3be3b337299f',
    ),
    'Hybrid pour over espresso': (
      BeverageType.espresso,
      'profile:5dcb9d71df6f51e695b8',
    ),
    'Innovative long preinfusion': (
      BeverageType.espresso,
      'profile:474283e3a1fe28dc288c',
    ),
    'Italian Australian espresso': (
      BeverageType.espresso,
      'profile:06788710759408842c45',
    ),
    'Low pressure lever machine at 6 bar': (
      BeverageType.espresso,
      'profile:d555bef4d3eabbdef1c5',
    ),
    'Steam only': (BeverageType.espresso, 'profile:cd62fa222bb9f96ee318'),
    'Cleaning/Forward flush': (
      BeverageType.cleaning,
      'profile:be84050f7564ed7e7cce',
    ),
    'Test/Flow calibration': (
      BeverageType.calibrate,
      'profile:ebbb87f21857d2265eca',
    ),
    'Test/for a small leak': (
      BeverageType.calibrate,
      'profile:e25775e340d9105fb043',
    ),
    'Test/leakage stress test': (
      BeverageType.calibrate,
      'profile:27405f374ef44c8a96ef',
    ),
    'Test/low pressure leak': (
      BeverageType.calibrate,
      'profile:df9b460c57d718fe7a26',
    ),
    'Test/pressure calibration': (
      BeverageType.calibrate,
      'profile:622c4e81ee33585caced',
    ),
    'Test/temperature accuracy': (
      BeverageType.calibrate,
      'profile:109e603197b501223f15',
    ),
    'Test/temperature calibration': (
      BeverageType.calibrate,
      'profile:dc4323dd98c57603d583',
    ),
  };

  Profile porting(String title) {
    final match = profiles.values.where((p) => p.title == title);
    expect(match, hasLength(1), reason: '$title must stay bundled');
    return match.single;
  }

  test('profiles ported from de1app keep their source beverage type', () {
    final byTitle = {for (final p in profiles.values) p.title: p.beverageType};
    for (final entry in ported.entries) {
      expect(
        byTitle[entry.key],
        entry.value.$1,
        reason: '${entry.key} must stay bundled as ${entry.value.$1.name}',
      );
    }
  });

  test('profiles ported from de1app keep their source execution content', () {
    for (final entry in ported.entries) {
      expect(
        ProfileHash.calculateProfileHash(porting(entry.key)),
        entry.value.$2,
        reason: '${entry.key} drifted from its de1app source',
      );
    }
  });

  test('Test/profile_editor_demo is not bundled', () {
    // de1app marks it a dummy for its profile_editor framework; Decaid's
    // Profile model carries no such extension, so the port would only ship a
    // runnable copy of D-Flow Q under a diagnostic title.
    expect(
      profiles.values.map((p) => p.title),
      isNot(contains('Test/profile_editor_demo')),
    );
    expect(files, isNot(contains('Test_profile_editor_demo.json')));
  });

  test('Test/leakage stress test keeps its 12 bar pressure cycle', () {
    final steps = porting('Test/leakage stress test').steps;
    expect(steps, hasLength(19));
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final up = i.isEven;
      expect(step.name, up ? 'Pressure up' : 'Pressure release');
      expect(step, isA<ProfileStepPressure>(), reason: 'step $i');
      expect(
        (step as ProfileStepPressure).pressure,
        up ? 12.0 : 0.0,
        reason: 'step $i',
      );
      expect(step.transition, TransitionType.fast, reason: 'step $i');
      expect(step.seconds, up ? (i == 0 ? 10.0 : 5.0) : 1.0, reason: 'step $i');
      expect(step.exit, isNull, reason: 'step $i');
      expect(step.limiter, isNull, reason: 'step $i');
    }
  });

  test('Test/Flow calibration steps 1 bar to 9 bar under a flow limiter', () {
    final steps = porting('Test/Flow calibration').steps;
    expect(steps, hasLength(9));
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      expect(step.name, '${i + 1} bar');
      expect(step, isA<ProfileStepPressure>(), reason: 'step $i');
      expect(
        (step as ProfileStepPressure).pressure,
        (i + 1).toDouble(),
        reason: 'step $i',
      );
      expect(step.temperature, 90.0, reason: 'step $i');
      expect(step.seconds, i == 0 ? 20.0 : 15.0, reason: 'step $i');
      expect(step.exit, isNull, reason: 'step $i');
      expect(step.limiter?.value, 0.0, reason: 'step $i');
      expect(step.limiter?.range, 0.6, reason: 'step $i');
    }
  });

  test('Best overall pressure profile keeps its rise and decline stages', () {
    final steps = porting('Best overall pressure profile').steps;
    expect(steps.map((s) => s.name), <String>[
      'preinfusion temp boost',
      'preinfusion',
      'forced rise without limit',
      'rise and hold',
      'decline',
    ]);

    for (final step in steps.take(2)) {
      expect(step, isA<ProfileStepFlow>());
      expect((step as ProfileStepFlow).flow, 8.0);
      expect(step.exit?.type, ExitType.pressure);
      expect(step.exit?.condition, ExitCondition.over);
      expect(step.exit?.value, 4.0);
    }

    final rise = steps[3] as ProfileStepPressure;
    expect(rise.pressure, 8.4);
    expect(rise.transition, TransitionType.fast);
    expect(rise.limiter?.value, 3.5);

    final decline = steps[4] as ProfileStepPressure;
    expect(decline.pressure, 6.0);
    expect(decline.transition, TransitionType.smooth);
    expect(decline.seconds, 30.0);
    expect(decline.limiter?.value, 3.5);
  });
}
