import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_version.dart';

void main() {
  group('shouldReplaceBundledPlugin', () {
    test('requires a strictly newer bundle and ignores build metadata', () {
      expect(shouldReplaceBundledPlugin('1.0.0', '1.0.0'), isFalse);
      expect(shouldReplaceBundledPlugin('1.0.0', '2.0.0'), isFalse);
      expect(shouldReplaceBundledPlugin('1.0.0', '0.9.0'), isTrue);
      expect(shouldReplaceBundledPlugin('1.10.0', '1.9.0'), isTrue);
      expect(shouldReplaceBundledPlugin('1.0.0+a', '1.0.0+b'), isFalse);
      expect(shouldReplaceBundledPlugin('1.0.0+b', '1.0.0+a'), isFalse);
      expect(shouldReplaceBundledPlugin('1.0.1+a', '1.0.0+b'), isTrue);
    });

    test('orders prereleases below releases and identifiers numerically', () {
      expect(shouldReplaceBundledPlugin('0.12.1', '0.12.1-dev.2'), isTrue);
      expect(shouldReplaceBundledPlugin('0.12.1-dev.2', '0.12.1'), isFalse);
      expect(
        shouldReplaceBundledPlugin('0.12.1-dev.10', '0.12.1-dev.2'),
        isTrue,
      );
    });

    for (final pair in [
      (bundled: '1.0.0-2', installed: '1.0.0-0x1'),
      (bundled: '1.0.0-0', installed: '1.0.0--1'),
    ]) {
      test('numeric prerelease ranks below ${pair.installed}', () {
        expect(
          shouldReplaceBundledPlugin(pair.bundled, pair.installed),
          isFalse,
        );
        expect(
          shouldReplaceBundledPlugin(pair.installed, pair.bundled),
          isTrue,
        );
      });
    }

    for (final version in [
      '01.0.0',
      '1.01.0',
      '1.0.01',
      '1.0.0-01',
      '1.0.0-alpha.01',
    ]) {
      test('rejects bundled leading zeros: $version', () {
        expect(shouldReplaceBundledPlugin(version, '0.0.1'), isFalse);
      });
      test('rejects installed leading zeros: $version', () {
        expect(shouldReplaceBundledPlugin('9.0.0', version), isFalse);
      });
    }

    test('overflowing numeric prerelease does not outrank alphanumeric', () {
      expect(
        shouldReplaceBundledPlugin('1.0.0-99999999999999999999', '1.0.0-0x1'),
        isFalse,
      );
    });

    test('fails closed between overflowing numeric prereleases', () {
      expect(
        shouldReplaceBundledPlugin(
          '1.0.0-99999999999999999999',
          '1.0.0-100000000000000000000',
        ),
        isFalse,
      );
    });

    test('fails closed for overflowing bundled numeric prerelease', () {
      expect(
        shouldReplaceBundledPlugin('1.0.0-alpha.99999999999999999999', '0.0.1'),
        isFalse,
      );
    });

    test('fails closed for overflowing installed numeric prerelease', () {
      expect(
        shouldReplaceBundledPlugin('9.0.0', '1.0.0-alpha.99999999999999999999'),
        isFalse,
      );
    });

    test('permits leading zeros in build metadata without ordering by it', () {
      expect(shouldReplaceBundledPlugin('1.0.0+01', '0.9.0'), isTrue);
      expect(shouldReplaceBundledPlugin('1.0.1', '1.0.0+01'), isTrue);
      expect(shouldReplaceBundledPlugin('1.0.0+01', '1.0.0+02'), isFalse);
      expect(shouldReplaceBundledPlugin('1.0.0+02', '1.0.0+01'), isFalse);
    });

    test(
      'fails closed for missing or malformed complete versions on either side',
      () {
        for (final version in <String?>[
          null,
          '',
          'dist',
          '1.x.0',
          '1',
          '1.0',
          '1.0.0.1',
          '1..0',
          '-1.0.0',
          '1.0.0-',
          '1.0.0-dev..2',
          '1.0.0+',
          '1.0.0+a..b',
          '1.0.0+build+again',
          ' 1.0.0',
          '1.0.0 ',
          '999999999999999999999999.0.0',
        ]) {
          expect(
            shouldReplaceBundledPlugin(version, '0.0.1'),
            isFalse,
            reason: 'invalid bundle: $version',
          );
          expect(
            shouldReplaceBundledPlugin('9.0.0', version),
            isFalse,
            reason: 'invalid installation: $version',
          );
        }
      },
    );
  });

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

    test(
      'preserves legacy install-time coercion of invalid components to zero',
      () {
        expect(comparePluginVersions('1.x.0', '1.0.0'), 0);
        expect(comparePluginVersions('', '0.0.0'), 0);
      },
    );
  });
}
