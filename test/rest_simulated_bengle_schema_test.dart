import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('REST request and response schemas accept simulated Bengle', () async {
    final spec = await File('assets/api/rest_v1.yml').readAsString();
    expect(
      RegExp(
        r'enum: \[machine, scale, sensor, bengle, grinder\]',
      ).allMatches(spec).length,
      2,
    );
  });
}
