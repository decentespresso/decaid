import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('personal builds do not configure the upstream macOS updater', () {
    final mainSource = File('lib/main.dart').readAsStringSync();

    expect(
      mainSource,
      contains('if (!personalBuild && macosUpdater != null)'),
    );
  });
}
