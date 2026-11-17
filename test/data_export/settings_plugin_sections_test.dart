import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bundled settings UI and API contract include all registered sections',
    () async {
      final plugin = await File('assets/plugins/settings.reaplugin/plugin.js')
          .readAsString();
      final spec = await File('assets/api/rest_v1.yml').readAsString();

      for (final section in ['steams', 'beans', 'grinders']) {
        expect(plugin, contains('value="$section"'));
        expect(spec, contains(section));
      }
    },
  );
}
