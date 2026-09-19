import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/connection_attempt_owner.dart';

void main() {
  group('ConnectionAttemptOwner', () {
    test(
      'cancelled attempt stays blocked until that exact attempt settles',
      () {
        final owner = ConnectionAttemptOwner();
        final attempt = owner.acquire('AA:BB', automatic: true)!;

        expect(attempt.mayAdopt, isTrue);
        expect(attempt.cancel(), isTrue);
        expect(attempt.mayAdopt, isFalse);
        expect(owner.active, contains(same(attempt)));
        expect(owner.acquire('aa:bb'), isNull);

        expect(attempt.settle(), isTrue);
        expect(owner.acquire('AA:BB'), isNotNull);
      },
    );

    test('activeFor normalizes device ids', () {
      final owner = ConnectionAttemptOwner();
      final attempt = owner.acquire('AA:BB')!;

      expect(owner.activeFor('aa:bb'), same(attempt));
    });

    test('repeated cancel is idempotent', () {
      final owner = ConnectionAttemptOwner();
      final attempt = owner.acquire('AA:BB')!;

      expect(attempt.cancel(), isTrue);
      expect(attempt.cancel(), isFalse);
      expect(owner.active, contains(same(attempt)));
    });

    test('stale settle cannot release a replacement attempt', () {
      final owner = ConnectionAttemptOwner();
      final first = owner.acquire('device-1')!;
      expect(first.settle(), isTrue);

      final replacement = owner.acquire('DEVICE-1')!;
      expect(first.settle(), isFalse);
      expect(owner.active, contains(same(replacement)));
      expect(replacement.mayAdopt, isTrue);
    });

    test('stale cancel cannot cancel a replacement attempt', () {
      final owner = ConnectionAttemptOwner();
      final first = owner.acquire('device-1')!;
      expect(first.settle(), isTrue);

      final replacement = owner.acquire('device-1')!;
      expect(first.cancel(), isFalse);
      expect(replacement.cancelled, isFalse);
      expect(replacement.mayAdopt, isTrue);
    });

    test('different device ids remain independent', () {
      final owner = ConnectionAttemptOwner();
      final machine = owner.acquire('machine')!;
      final scale = owner.acquire('scale')!;

      expect(machine.cancel(), isTrue);
      expect(machine.mayAdopt, isFalse);
      expect(scale.mayAdopt, isTrue);
      expect(owner.active, contains(same(scale)));
    });
  });
}
