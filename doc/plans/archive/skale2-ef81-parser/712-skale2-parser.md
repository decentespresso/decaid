---
repo: /Users/vid/development/repos/reaprime
worker: omlx/Qwen3.5-9B-4bit
overseer: deepseek/deepseek-v4-flash
max_steps: 20
files:
  - lib/src/models/device/impl/skale/skale2_scale.dart
  - test/unit/models/skale2_scale_test.dart
verify:
  - dart format --set-exit-if-changed lib/src/models/device/impl/skale/skale2_scale.dart test/unit/models/skale2_scale_test.dart
  - flutter test test/unit/models/skale2_scale_test.dart
  - flutter test test/unit/models
  - flutter analyze
---

# Decaid #712 — Correct Atomax Skale EF81 5-byte weight parsing

Implementation instructions for a small model. Work in `/Users/vid/development/repos/reaprime`. Do exactly one step at a time, in order. Stop after each step and report. Never commit, push, or open a PR.

Rules that apply to EVERY step:

- Change ONLY the files a step names. Never touch `pubspec.yaml` or `pubspec.lock`. Never run `flutter pub get`, `flutter pub add`, or any package install.
- Never delete, rename, reorder, or reformat existing code unless the step says so. Never rewrite a whole file.
- Never delete stored credentials or user data.
- After every edit: read the file back and confirm the change is present, then run the check the step gives you. Copy the command output into your report verbatim (do not summarize or paraphrase it).
- If a command fails or output does not match the step's expectation, STOP and report the exact output. Do not guess, do not "fix" beyond the step.
- `doc/plans/712-skale2-parser.md` is the harness plan file: it is intentionally untracked. Ignore it in `git status`. Do not add, commit, or delete it.
- End your reply with a line starting with `DONE:` saying what you changed.

## 1. Read the code and record the baseline

Read these files completely:

- `lib/src/models/device/impl/skale/skale2_scale.dart`
- `test/unit/models/skale2_scale_test.dart`

Then run these commands and copy their FULL output into your report verbatim:

```bash
flutter test test/unit/models/skale2_scale_test.dart
flutter test test/unit/models
flutter analyze
```

Baseline expectation (measured before this work): the focused file has 14 tests and all pass; `test/unit/models` has 342 tests and all pass; `flutter analyze` reports `No issues found!`. If the outputs differ, record them verbatim and continue — do NOT try to fix pre-existing failures.

Report, in three short bullets:

1. How `_parseWeightNotification` in `lib/src/models/device/impl/skale/skale2_scale.dart` currently decodes a notification (which bytes, which endianness, which divisor, and what it does with frames shorter than 4 bytes).
2. The test pattern in the `Skale2Scale weight notification parsing` group: the `_RecordableBleTransport`, `simulateWeightNotification`, the `Completer<ScaleSnapshot>` + `timeout` pattern, and the group `setUp`.
3. The three baseline results above.

Do not change any code.

## 2. Add the math import

Edit ONLY `lib/src/models/device/impl/skale/skale2_scale.dart`.

The file starts with these two import lines:

```dart
import 'dart:async';
import 'dart:typed_data';
```

Insert exactly one new line between them, so that the top of the file reads exactly (copy character for character):

```dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
```

Do NOT add, remove, or change any other line. The blank line that follows the three imports must remain exactly one blank line. Read the file back and confirm the three import lines are present in that exact order.

Verify with:

```bash
dart analyze lib/src/models/device/impl/skale/skale2_scale.dart
```

Expect `No issues found!`. Copy the output into your report.

## 3. Replace _parseWeightNotification with the length-based decoder

Edit ONLY `lib/src/models/device/impl/skale/skale2_scale.dart`.

Find the method `_parseWeightNotification`. It currently reads exactly:

```dart
  void _parseWeightNotification(List<int> data) {
    if (data.length < 4) return;

    final byteData = ByteData(4);
    byteData.setUint8(0, data[0] & 0xFF);
    byteData.setUint8(1, data[1] & 0xFF);
    byteData.setUint8(2, data[2] & 0xFF);
    byteData.setUint8(3, data[3] & 0xFF);
    final rawValue = byteData.getInt32(0, Endian.little);

    final weight = rawValue / 2560.0;

    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight,
        batteryLevel: _batteryLevel,
      ),
    );
  }
```

Replace the ENTIRE method (from the line `void _parseWeightNotification(List<int> data) {` through the closing `  }` that ends the method) with exactly this — copy character for character:

```dart
  void _parseWeightNotification(List<int> data) {
    double? weight;
    if (data.length == 5) {
      var mantissa =
          (data[1] & 0xFF) | ((data[2] & 0xFF) << 8) | ((data[3] & 0xFF) << 16);
      if (mantissa & 0x800000 != 0) {
        mantissa -= 0x1000000;
      }
      final rawExponent = data[4];
      final exponent = rawExponent >= 0x80 ? rawExponent - 256 : rawExponent;
      weight = mantissa * math.pow(10, exponent).toDouble();
    } else if (data.length == 4) {
      final byteData = ByteData(4);
      byteData.setUint8(0, data[0] & 0xFF);
      byteData.setUint8(1, data[1] & 0xFF);
      byteData.setUint8(2, data[2] & 0xFF);
      byteData.setUint8(3, data[3] & 0xFF);
      final rawValue = byteData.getInt32(0, Endian.little);
      weight = rawValue / 2560.0;
    } else {
      return;
    }
    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight,
        batteryLevel: _batteryLevel,
      ),
    );
  }
```

Do NOT change anything else in the file. Do NOT add any logging. Do NOT add a new public method.

Read the file back and confirm:

- the method now has three branches (`data.length == 5`, `data.length == 4`, `else return`);
- the old `if (data.length < 4) return;` line is gone;
- the `/ 2560.0` division appears ONLY inside the `data.length == 4` branch;
- a 5-byte frame can no longer reach the `/ 2560.0` division.

Verify with:

```bash
dart analyze lib/src/models/device/impl/skale/skale2_scale.dart
```

Expect `No issues found!`. Copy the output into your report.

## 4. Add tests: SDK fractional and SDK negative

Edit ONLY `test/unit/models/skale2_scale_test.dart`.

Open the end of the file. The final two lines are always the group's closing line `  });` followed by the closing line `}` of `main()`:

```dart
  });
}
```

Insert the following two tests immediately BEFORE the `  });` line. Do NOT change the `  });` line or the final `}` line. Copy character for character:

```dart
    test(
      'parses SDK 5-byte fractional weight (00 D2 04 00 FE -> 12.34)',
      () async {
        final completer = Completer<ScaleSnapshot>();
        final sub = scale.currentSnapshot.listen((snapshot) {
          if (!completer.isCompleted) completer.complete(snapshot);
        });

        transport.simulateWeightNotification([0x00, 0xD2, 0x04, 0x00, 0xFE]);

        final snapshot = await completer.future.timeout(
          const Duration(seconds: 1),
        );

        expect(snapshot.weight, closeTo(12.34, 0.001));

        await sub.cancel();
      },
    );

    test(
      'parses SDK 5-byte negative weight (00 C9 FD FF FF -> -56.7)',
      () async {
        final completer = Completer<ScaleSnapshot>();
        final sub = scale.currentSnapshot.listen((snapshot) {
          if (!completer.isCompleted) completer.complete(snapshot);
        });

        transport.simulateWeightNotification([0x00, 0xC9, 0xFD, 0xFF, 0xFF]);

        final snapshot = await completer.future.timeout(
          const Duration(seconds: 1),
        );

        expect(snapshot.weight, closeTo(-56.7, 0.001));

        await sub.cancel();
      },
    );
```

Whitespace rules for this insertion: keep exactly one blank line between the last existing test and the first new test, and exactly one blank line between the two new tests. The group's closing `  });` line must follow the final line of the last inserted test directly, with NO blank line between them. The final `}` must stay the very last line of the file.

Do NOT modify the existing `parses weight notification correctly` test. Read the file back and confirm both new tests are present before the group's closing `  });`.

Run both and confirm they pass (copy both outputs verbatim):

```bash
flutter test test/unit/models/skale2_scale_test.dart --plain-name "fractional weight"
flutter test test/unit/models/skale2_scale_test.dart --plain-name "negative weight"
```

## 5. Add tests: SDK positive exponent and common exponent -1

Edit ONLY `test/unit/models/skale2_scale_test.dart`.

The final two lines of the file are still the group's closing line `  });` followed by the closing line `}` of `main()`:

```dart
  });
}
```

Insert the following two tests immediately BEFORE the `  });` line. Do NOT change the `  });` line or the final `}` line. Copy character for character:

```dart
    test(
      'parses SDK 5-byte positive exponent (00 7B 00 00 01 -> 1230.0)',
      () async {
        final completer = Completer<ScaleSnapshot>();
        final sub = scale.currentSnapshot.listen((snapshot) {
          if (!completer.isCompleted) completer.complete(snapshot);
        });

        transport.simulateWeightNotification([0x00, 0x7B, 0x00, 0x00, 0x01]);

        final snapshot = await completer.future.timeout(
          const Duration(seconds: 1),
        );

        expect(snapshot.weight, closeTo(1230.0, 0.001));

        await sub.cancel();
      },
    );

    test(
      'parses SDK 5-byte common exponent -1 (00 E8 03 00 FF -> 100.0)',
      () async {
        final completer = Completer<ScaleSnapshot>();
        final sub = scale.currentSnapshot.listen((snapshot) {
          if (!completer.isCompleted) completer.complete(snapshot);
        });

        transport.simulateWeightNotification([0x00, 0xE8, 0x03, 0x00, 0xFF]);

        final snapshot = await completer.future.timeout(
          const Duration(seconds: 1),
        );

        expect(snapshot.weight, closeTo(100.0, 0.001));

        await sub.cancel();
      },
    );
```

Whitespace rules for this insertion: keep exactly one blank line between the previous test and the first new test, and exactly one blank line between the two new tests. The group's closing `  });` line must follow the final line of the last inserted test directly, with NO blank line between them. The final `}` must stay the very last line of the file.

Do NOT modify any existing test. Read the file back and confirm both new tests are present before the group's closing `  });`.

Run both and confirm they pass (copy both outputs verbatim):

```bash
flutter test test/unit/models/skale2_scale_test.dart --plain-name "positive exponent"
flutter test test/unit/models/skale2_scale_test.dart --plain-name "common exponent"
```

## 6. Add tests: legacy four-byte, truncated, oversized

Edit ONLY `test/unit/models/skale2_scale_test.dart`.

The final two lines of the file are still the group's closing line `  });` followed by the closing line `}` of `main()`:

```dart
  });
}
```

Insert the following three tests immediately BEFORE the `  });` line. Do NOT change the `  });` line or the final `}` line. Copy character for character:

```dart
    test('parses legacy four-byte frame (00 0A 00 00 -> 1.0)', () async {
      final completer = Completer<ScaleSnapshot>();
      final sub = scale.currentSnapshot.listen((snapshot) {
        if (!completer.isCompleted) completer.complete(snapshot);
      });

      transport.simulateWeightNotification([0x00, 0x0A, 0x00, 0x00]);

      final snapshot = await completer.future.timeout(
        const Duration(seconds: 1),
      );

      expect(snapshot.weight, closeTo(1.0, 0.001));

      await sub.cancel();
    });

    test('ignores truncated three-byte frame (no snapshot)', () async {
      var emissions = 0;
      final sub = scale.currentSnapshot.listen((_) => emissions++);

      transport.simulateWeightNotification([0x00, 0xD2, 0x04]);

      await Future.delayed(const Duration(milliseconds: 100));
      expect(emissions, 0);

      await sub.cancel();
    });

    test('ignores oversized six-byte frame (no snapshot)', () async {
      var emissions = 0;
      final sub = scale.currentSnapshot.listen((_) => emissions++);

      transport.simulateWeightNotification([
        0x00,
        0xE8,
        0x03,
        0x00,
        0xFF,
        0x00,
      ]);

      await Future.delayed(const Duration(milliseconds: 100));
      expect(emissions, 0);

      await sub.cancel();
    });
```

Whitespace rules for this insertion: keep exactly one blank line between each pair of tests. The group's closing `  });` line must follow the final line of the last inserted test directly, with NO blank line between them. The final `}` must stay the very last line of the file.

Do NOT modify any existing test. Read the file back and confirm all three new tests are present before the group's closing `  });`.

Run all three and confirm they pass (copy all three outputs verbatim):

```bash
flutter test test/unit/models/skale2_scale_test.dart --plain-name "legacy four-byte frame"
flutter test test/unit/models/skale2_scale_test.dart --plain-name "truncated three-byte"
flutter test test/unit/models/skale2_scale_test.dart --plain-name "oversized six-byte"
```

## 7. Run the full focused suite

Run:

```bash
flutter test test/unit/models/skale2_scale_test.dart
```

Expect 21 tests (14 original + 7 new), all passing. Copy the full output into your report. If any test fails, STOP and report the failure output. Do not fix anything.

## 8. Format and analyze

Run these commands and copy their FULL output verbatim:

```bash
dart format lib/src/models/device/impl/skale/skale2_scale.dart test/unit/models/skale2_scale_test.dart
flutter analyze
```

Expect: the format command exits 0 and prints `Formatted 2 files` (it may print `(0 changed)` or `(1 changed)` — both are fine, exit 0 is what matters); `flutter analyze` prints `No issues found!`.

Rules for this step:

- Format ONLY the two named files. Do NOT run `dart format lib test` or any broader format command.
- `dart format` may normalize whitespace in the two files (for example, collapsing a double blank line). That is expected and desired. It is the ONLY edit you may make in this step.
- Do NOT touch any other file, even if `flutter analyze` reports issues elsewhere. Report any issues verbatim.

## 9. Review the diff

Run these commands and copy their full output into your report:

```bash
git status --short
git diff --stat
git diff lib/src/models/device/impl/skale/skale2_scale.dart
```

Do NOT edit any file. Do NOT run `git diff` with pagination.

Report, for each changed file: the file name and whether it is one of the two expected files (`lib/src/models/device/impl/skale/skale2_scale.dart`, `test/unit/models/skale2_scale_test.dart`). `doc/plans/712-skale2-parser.md` is the harness plan file — intentionally untracked, ignore it. If any OTHER file is in the diff, STOP and report it.

In the source diff, confirm and report:

1. The 5-byte branch builds a 24-bit LE mantissa from bytes 1..3 with manual sign extension (`0x800000` -> subtract `0x1000000`) and decodes byte 4 as a signed base-10 exponent (`>= 0x80` -> `- 256`).
2. The `/ 2560.0` legacy division exists ONLY inside the `data.length == 4` branch, so a 5-byte notification can no longer reach it.
3. No logging, no new public API, and no other method in the file changed.

## 10. Report back

Report, in this order:

1. Files changed (list).
2. Decoding behavior before/after (two sentences: before = bytes 0..3 signed LE int32 divided by 2560 for any frame of 4+ bytes; after = 5-byte frames use mantissa*10^exponent, 4-byte frames keep the old /2560 decoding, all other lengths emit nothing).
3. Tests added (list of the seven test names).
4. Checks run and results (one line each, with the verbatim output you already copied).
5. Any discrepancy you discovered between issue #712's assumed packet format and existing code/evidence (for example: the retained legacy test `parses weight notification correctly` uses the 4-byte frame `00 E8 03 00` -> `100.0`, which numerically coincides with the new 5-byte SDK example `00 E8 03 00 FF` -> `100.0`; note anything else you observed).
6. Anything you were unsure about.

Do not commit, push, or open a PR.
