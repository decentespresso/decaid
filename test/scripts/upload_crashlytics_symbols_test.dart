import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('personal builds skip Crashlytics symbol uploads', () async {
    final result = await Process.run(
      '/bin/bash',
      ['scripts/upload_crashlytics_symbols.sh', 'macos'],
      environment: const {'PERSONAL_BUILD': 'true'},
      includeParentEnvironment: false,
    );

    expect(result.exitCode, 0);
    expect(result.stdout, contains('personal build'));
  });
}
