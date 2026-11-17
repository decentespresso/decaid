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
  final rawByTitle = <String, Map<String, dynamic>>{};

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
      rawByTitle[profiles[f]!.title] = json;
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
  //
  // Each entry pins four things: the beverage type, the execution hash, the
  // metadata hash and the raw JSON "type".
  //
  //   ProfileHash.calculateProfileHash  - version, beverage type, tank
  //     temperature, target weight, target volume, target volume count start
  //     and every field of every step.
  //   ProfileHash.calculateMetadataHash - title, author and notes, so an
  //     accidental edit to the verbatim de1app notes (double spaces included)
  //     fails instead of silently drifting from the source.
  //
  // Together the hashes cover every field Profile.fromJson retains. They do
  // not cover the two top-level JSON keys the model drops:
  //
  //   type   - pinned separately below, read off the raw JSON, from the
  //     source's settings_profile_type (settings_2a pressure, settings_2b
  //     flow, settings_2c advanced).
  //   hidden - deliberately unpinned. de1app sets profile_hide 1 on 20 of
  //     these 21 sources; per maintainer direction Decaid bundles them all
  //     visible, so this field is an intended difference, not drift.
  //
  // A failure means a ported profile drifted from its de1app source: re-check
  // against that revision before touching the expected value.
  const ported = <String, (BeverageType, String, String, String)>{
    'Best overall pressure profile': (
      BeverageType.espresso,
      'profile:f1b836e535b0b57f44a2',
      '35282ad36baa117d4a69abc143035bfcf01bb7b2c9ba05ec2d30f7575ee3f5cd',
      'pressure',
    ),
    'E61 espresso machine': (
      BeverageType.espresso,
      'profile:28d47321846585be3d40',
      '5fcfeb2d71960039d790bb851d7d4344d0bf6c5fc1d3d2b4de634a431a4fdcc4',
      'pressure',
    ),
    'E61 classic gently up to 10 bar': (
      BeverageType.espresso,
      'profile:9e902a31f13fb8ea2c8e',
      'f14447f40db99741e5e8006bd061de3698c0490df6ae540696b7817338fe1769',
      'pressure',
    ),
    'E61 rocketing up to 10 bar': (
      BeverageType.espresso,
      'profile:242a62e1111b4a1bc47e',
      'a797bcb318208ddb3f7948d17cfd38ec013208df51501266adcd56681481b83b',
      'pressure',
    ),
    'E61 with fast preinfusion to 9 bar': (
      BeverageType.espresso,
      'profile:badeb80f41ebf99c93e3',
      '32058a06eacff7bc6d558dff3fd6f96507eef267fd8e9c7ee3367dec17dfcc51',
      'pressure',
    ),
    'Gentle flat 2.5 ml per second': (
      BeverageType.espresso,
      'profile:0ef8e395628904bd569a',
      'dfb0c4338e6a9f8a29bcedcc4ddc19a2b76be43f9f262ffc4597e58a8e86e74b',
      'flow',
    ),
    'Gentle preinfusion flow profile': (
      BeverageType.espresso,
      'profile:676679ab3b3a0aff25c6',
      'b8e7762cc5b39a4127fe17ef9da8e69ca52cf76bd36969a5ba30c36f496ed4fe',
      'flow',
    ),
    'Gentler but still traditional 8.4 bar': (
      BeverageType.espresso,
      'profile:a258c0df3be3b337299f',
      '06cff18f289b192dc7a416304400abe88114db9df0e0c9015f56622f3fee2640',
      'pressure',
    ),
    'Hybrid pour over espresso': (
      BeverageType.espresso,
      'profile:5dcb9d71df6f51e695b8',
      'cf26b7fba509805d866b180ad3bc993d8ee09103341f6803657e078597595ff9',
      'flow',
    ),
    'Innovative long preinfusion': (
      BeverageType.espresso,
      'profile:474283e3a1fe28dc288c',
      '1d37dd97bd8e30d05e442f20c9904fd4694ff1401fb46e8da7e1b81661d869dd',
      'flow',
    ),
    'Italian Australian espresso': (
      BeverageType.espresso,
      'profile:06788710759408842c45',
      'ef7387d03651b210ceb5e9b87a11ca0d128b0cd8b81a86b8b401bf5f6861a2a5',
      'pressure',
    ),
    'Low pressure lever machine at 6 bar': (
      BeverageType.espresso,
      'profile:d555bef4d3eabbdef1c5',
      '3a460b0b901796be65b4c1006a21b1c6d1ba7aef67fa99a82100991dbc496432',
      'pressure',
    ),
    'Steam only': (
      BeverageType.espresso,
      'profile:cd62fa222bb9f96ee318',
      '6bc803f0756c748227efd80a21266bb23cc1074d2eadcac449567f3ea5db54e4',
      'pressure',
    ),
    'Cleaning/Forward flush': (
      BeverageType.cleaning,
      'profile:be84050f7564ed7e7cce',
      'b95798ae80abf1b5c29fe3e3a8950abe359c23fc6fc715192aac1ebfafcfd175',
      'advanced',
    ),
    'Test/Flow calibration': (
      BeverageType.calibrate,
      'profile:ebbb87f21857d2265eca',
      'f2e446801d41a505cb260b49d215b4fcda7fbb27d0bc4b3cf441d8ea541f9377',
      'advanced',
    ),
    'Test/for a small leak': (
      BeverageType.calibrate,
      'profile:e25775e340d9105fb043',
      'f5564c057ed6532a80ffd703aa6c1c6f2ad8dbfd2f8bd6ddb0b1e1ad16d73cdb',
      'advanced',
    ),
    'Test/leakage stress test': (
      BeverageType.calibrate,
      'profile:27405f374ef44c8a96ef',
      '423b98697233e86c7190827a0ef11688e3a84dfda1c98429222090aec5daf92a',
      'advanced',
    ),
    'Test/low pressure leak': (
      BeverageType.calibrate,
      'profile:df9b460c57d718fe7a26',
      '78d0b37ea3985ab49fef07fd62eae9c618078da25ae0cedf23767ee2bbfcecd9',
      'advanced',
    ),
    'Test/pressure calibration': (
      BeverageType.calibrate,
      'profile:622c4e81ee33585caced',
      '469ff044d412af4d403bb2dd13996244e590e1d2e0908a7ec08106e31cd29df5',
      'advanced',
    ),
    'Test/temperature accuracy': (
      BeverageType.calibrate,
      'profile:109e603197b501223f15',
      '2a5e29b1afdca7407044be86ef4f0c7f65f3cf3078dfe991dbf39c3f9edcbeaa',
      'advanced',
    ),
    'Test/temperature calibration': (
      BeverageType.calibrate,
      'profile:dc4323dd98c57603d583',
      'c2f3a58e3d599df6470d7b3b56784ff980b4d68af80af8481d8a2d84259d6a0d',
      'flow',
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

  test('profiles ported from de1app keep their source metadata', () {
    for (final entry in ported.entries) {
      expect(
        ProfileHash.calculateMetadataHash(porting(entry.key)),
        entry.value.$3,
        reason:
            '${entry.key}: title, author or notes drifted from its de1app '
            'source',
      );
    }
  });

  test('profiles ported from de1app keep their source profile type', () {
    for (final entry in ported.entries) {
      porting(entry.key);
      expect(
        rawByTitle[entry.key]?['type'],
        entry.value.$4,
        reason:
            '${entry.key}: raw JSON "type" drifted from the source\'s '
            'settings_profile_type',
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
