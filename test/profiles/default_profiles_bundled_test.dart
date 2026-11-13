import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart'
    show BeverageType, ExitCondition, ExitType, Profile;
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

  test('profiles ported from de1app keep their source beverage type', () {
    const ported = <String, BeverageType>{
      'Best overall pressure profile': BeverageType.espresso,
      'E61 espresso machine': BeverageType.espresso,
      'E61 classic gently up to 10 bar': BeverageType.espresso,
      'E61 rocketing up to 10 bar': BeverageType.espresso,
      'E61 with fast preinfusion to 9 bar': BeverageType.espresso,
      'Gentle flat 2.5 ml per second': BeverageType.espresso,
      'Gentle preinfusion flow profile': BeverageType.espresso,
      'Gentler but still traditional 8.4 bar': BeverageType.espresso,
      'Hybrid pour over espresso': BeverageType.espresso,
      'Innovative long preinfusion': BeverageType.espresso,
      'Italian Australian espresso': BeverageType.espresso,
      'Low pressure lever machine at 6 bar': BeverageType.espresso,
      'Steam only': BeverageType.espresso,
      'Cleaning/Forward flush': BeverageType.cleaning,
      'Test/Flow calibration': BeverageType.calibrate,
      'Test/for a small leak': BeverageType.calibrate,
      'Test/leakage stress test': BeverageType.calibrate,
      'Test/low pressure leak': BeverageType.calibrate,
      'Test/pressure calibration': BeverageType.calibrate,
      'Test/profile_editor_demo': BeverageType.calibrate,
      'Test/temperature accuracy': BeverageType.calibrate,
      'Test/temperature calibration': BeverageType.calibrate,
    };
    final byTitle = {for (final p in profiles.values) p.title: p.beverageType};
    for (final entry in ported.entries) {
      expect(
        byTitle[entry.key],
        entry.value,
        reason: '${entry.key} must stay bundled as ${entry.value.name}',
      );
    }
  });
}
