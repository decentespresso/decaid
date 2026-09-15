import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/connection_attempt_owner.dart';

void main() {
  group('ConnectionAttemptOwner', () {
    test('cancelled attempt stays blocked until that exact attempt settles', () {
      final owner = ConnectionAttemptOwner();
      final attempt = owner.acquire('AA:BB', automatic: true)!;

      expect(attempt.mayAdopt, isTrue);
      expect(attempt.cancel(reason: 'timeout'), isTrue);
      expect(attempt.mayAdopt, isFalse);
      expect(owner.isBlocked('aa:bb'), isTrue);
      expect(owner.acquire('aa:bb'), isNull);

      expect(attempt.settle(), isTrue);
      expect(owner.isBlocked('AA:BB'), isFalse);
    });

    test('stale settle cannot release a replacement attempt', () {
      final owner = ConnectionAttemptOwner();
      final first = owner.acquire('device-1')!;
      expect(first.settle(), isTrue);

      final replacement = owner.acquire('DEVICE-1')!;
      expect(first.settle(), isFalse);
      expect(owner.activeFor('device-1'), same(replacement));
      expect(replacement.mayAdopt, isTrue);
    });

    test('stale cancel cannot cancel a replacement attempt', () {
      final owner = ConnectionAttemptOwner();
      final first = owner.acquire('device-1')!;
      expect(first.settle(), isTrue);

      final replacement = owner.acquire('device-1')!;
      expect(first.cancel(reason: 'late timeout'), isFalse);
      expect(replacement.cancelled, isFalse);
      expect(replacement.mayAdopt, isTrue);
    });

    test('different device ids remain independent', () {
      final owner = ConnectionAttemptOwner();
      final machine = owner.acquire('machine')!;
      final scale = owner.acquire('scale')!;

      expect(machine.cancel(reason: 'scan cancelled'), isTrue);
      expect(machine.mayAdopt, isFalse);
      expect(scale.mayAdopt, isTrue);
      expect(owner.isBlocked('scale'), isTrue);
    });

    test('diagnostics expose retiring ownership without releasing it', () {
      final owner = ConnectionAttemptOwner();
      final attempt = owner.acquire('AA:BB', automatic: true)!;
      attempt.cancel(reason: 'caller timeout');

      expect(owner.diagnosticsFor('aa:bb'), {
        'active': true,
        'deviceId': 'AA:BB',
        'generation': attempt.generation,
        'automatic': true,
        'cancelled': true,
        'cancelReason': 'caller timeout',
        'settled': false,
      });
    });
  });
}
