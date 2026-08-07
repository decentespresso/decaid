import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('skin_sources.json asset', () {
    test('can be loaded and parsed as a list of source configs', () async {
      final configString = await rootBundle.loadString('skin_sources.json');
      final sources = (jsonDecode(configString) as List)
          .cast<Map<String, dynamic>>();

      expect(sources, isNotEmpty);

      for (final source in sources) {
        expect(source, contains('type'));
        expect(source['type'], anyOf('github_release', 'github_branch', 'url'));
      }
    });
  });

  group('bundled_skins manifest', () {
    test('manifest.json can be loaded and contains skin IDs', () async {
      final manifestString = await rootBundle.loadString(
        'assets/bundled_skins/manifest.json',
      );
      final skinIds = (jsonDecode(manifestString) as List).cast<String>();

      expect(skinIds, isNotEmpty);
      for (final id in skinIds) {
        expect(id, isA<String>());
        expect(id, isNotEmpty);
      }
    });
  });
}
