import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_version.dart';

void main() {
  group('comparePluginVersions', () {
    test('orders numeric cores', () {
      expect(comparePluginVersions('1.0.0', '1.0.0'), 0);
      expect(comparePluginVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(comparePluginVersions('1.0.0', '1.0.1'), lessThan(0));
      expect(comparePluginVersions('1.10.0', '1.9.0'), greaterThan(0));
    });

    test('treats missing components as zero', () {
      expect(comparePluginVersions('1.0', '1.0.0'), 0);
      expect(comparePluginVersions('1', '1.0.1'), lessThan(0));
      expect(comparePluginVersions('1.2', '1.1.9'), greaterThan(0));
    });

    test('ranks a prerelease below its release', () {
      expect(comparePluginVersions('1.0.0-beta', '1.0.0'), lessThan(0));
      expect(comparePluginVersions('1.0.0', '1.0.0-beta'), greaterThan(0));
      expect(comparePluginVersions('1.0.0-beta', '0.9.9'), greaterThan(0));
    });

    test('orders prerelease identifiers', () {
      expect(comparePluginVersions('1.0.0-alpha', '1.0.0-beta'), lessThan(0));
      expect(
        comparePluginVersions('1.0.0-alpha.1', '1.0.0-alpha.2'),
        lessThan(0),
      );
      expect(
        comparePluginVersions('1.0.0-alpha.2', '1.0.0-alpha.10'),
        lessThan(0),
      );
      expect(
        comparePluginVersions('1.0.0-alpha', '1.0.0-alpha.1'),
        lessThan(0),
      );
      expect(comparePluginVersions('1.0.0-1', '1.0.0-alpha'), lessThan(0));
      expect(comparePluginVersions('1.0.0-beta.1', '1.0.0-beta.1'), 0);
    });

    test('ignores build metadata', () {
      expect(comparePluginVersions('1.0.0+build.5', '1.0.0'), 0);
      expect(comparePluginVersions('1.0.1+a', '1.0.0+b'), greaterThan(0));
    });

    test('treats unparseable components as zero', () {
      expect(comparePluginVersions('1.x.0', '1.0.0'), 0);
      expect(comparePluginVersions('', '0.0.0'), 0);
    });
  });
}
