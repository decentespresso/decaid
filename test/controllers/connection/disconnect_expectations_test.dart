import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/disconnect_expectations.dart';

void main() {
  group('DisconnectExpectations', () {
    test('consume returns false when nothing was marked', () {
      final e = DisconnectExpectations();
      expect(e.consume('id-1'), isFalse);
    });

    test('mark then consume returns true; second consume returns false', () {
      final e = DisconnectExpectations();
      e.mark('id-1');
      expect(e.consume('id-1'), isTrue);
      expect(e.consume('id-1'), isFalse);
    });

    test('marks for different ids are independent', () {
      final e = DisconnectExpectations();
      e.mark('a');
      e.mark('b');
      expect(e.consume('a'), isTrue);
      expect(e.consume('b'), isTrue);
    });

    test('TTL clears an un-consumed expectation', () {
      fakeAsync((async) {
        final e = DisconnectExpectations();
        e.mark('id-1');
        async.elapse(DisconnectExpectations.ttl + const Duration(seconds: 1));
        expect(
          e.consume('id-1'),
          isFalse,
          reason: 'mark should have expired after TTL',
        );
      });
    });

    test('re-marking the same id resets the TTL', () {
      fakeAsync((async) {
        final e = DisconnectExpectations();
        e.mark('id-1');
        async.elapse(DisconnectExpectations.ttl - const Duration(seconds: 1));
        e.mark('id-1');
        async.elapse(const Duration(seconds: 2));
        expect(
          e.consume('id-1'),
          isTrue,
          reason: 're-marked id should still be live',
        );
      });
    });

    test('dispose cancels pending timers and clears state', () {
      fakeAsync((async) {
        final e = DisconnectExpectations();
        e.mark('id-1');
        e.dispose();
        async.elapse(DisconnectExpectations.ttl + const Duration(seconds: 1));
        expect(e.consume('id-1'), isFalse);
      });
    });
  });
}
