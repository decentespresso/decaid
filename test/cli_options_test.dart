import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/cli/cli_args.dart';

void main() {
  group('parseCliArgs', () {
    test('no flags → all defaults', () {
      final args = parseCliArgs([]);
      expect(args.serial, isFalse);
      expect(args.bypassOnboarding, isFalse);
      expect(args.direct, isFalse);
      expect(args.noAccount, isFalse);
      expect(args.skinId, isNull);
      expect(args.skinPath, isNull);
    });

    test('--serial', () {
      final args = parseCliArgs(['--serial']);
      expect(args.serial, isTrue);
    });

    test('--bypass-onboarding', () {
      final args = parseCliArgs(['--bypass-onboarding']);
      expect(args.bypassOnboarding, isTrue);
    });

    test('--direct', () {
      final args = parseCliArgs(['--direct']);
      expect(args.direct, isTrue);
    });

    test('--skin=<id>', () {
      final args = parseCliArgs(['--skin=myskin.js']);
      expect(args.skinId, 'myskin.js');
    });

    test('--skin-path=<path>', () {
      final args = parseCliArgs(['--skin-path=/home/keith/myskin']);
      expect(args.skinPath, '/home/keith/myskin');
    });

    test('--no-account', () {
      final args = parseCliArgs(['--no-account']);
      expect(args.noAccount, isTrue);
    });

    test('--print-storage-paths', () {
      final args = parseCliArgs(['--print-storage-paths']);
      expect(args.printStoragePaths, isTrue);
    });

    test('all flags combined', () {
      final args = parseCliArgs([
        '--serial',
        '--bypass-onboarding',
        '--direct',
        '--no-account',
        '--skin=streamline.js',
        '--skin-path=/tmp/test-skin',
      ]);
      expect(args.serial, isTrue);
      expect(args.bypassOnboarding, isTrue);
      expect(args.direct, isTrue);
      expect(args.noAccount, isTrue);
      expect(args.skinId, 'streamline.js');
      expect(args.skinPath, '/tmp/test-skin');
    });

    test('--no-serial (negation)', () {
      final defaults = parseCliArgs([]);
      final negated = parseCliArgs(['--no-serial']);
      expect(negated.serial, isFalse);
      expect(negated.serial, defaults.serial);
    });
  });
}
