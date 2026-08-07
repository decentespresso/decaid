import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/ble/char_subscriptions.dart';

void main() {
  group('CharSubscriptions', () {
    test('re-adding the same UUID cancels the prior subscription', () async {
      final subs = CharSubscriptions();

      final c1 = StreamController<int>();
      final sub1 = c1.stream.listen((_) {});
      await subs.add('char-uuid', sub1);
      expect(c1.hasListener, isTrue);

      final c2 = StreamController<int>();
      final sub2 = c2.stream.listen((_) {});
      await subs.add('char-uuid', sub2);

      expect(
        c1.hasListener,
        isFalse,
        reason: 'first subscription should be cancelled on replace',
      );
      expect(
        c2.hasListener,
        isTrue,
        reason: 'newest subscription stays active',
      );

      await subs.cancelAll();
      addTearDown(() async {
        await c1.close();
        await c2.close();
      });
    });

    test('different UUIDs coexist', () async {
      final subs = CharSubscriptions();

      final ca = StreamController<int>();
      final cb = StreamController<int>();
      await subs.add('a', ca.stream.listen((_) {}));
      await subs.add('b', cb.stream.listen((_) {}));

      expect(ca.hasListener, isTrue);
      expect(cb.hasListener, isTrue);

      await subs.cancelAll();
      expect(ca.hasListener, isFalse);
      expect(cb.hasListener, isFalse);

      addTearDown(() async {
        await ca.close();
        await cb.close();
      });
    });

    test('cancelAll is idempotent', () async {
      final subs = CharSubscriptions();
      final c = StreamController<int>();
      await subs.add('a', c.stream.listen((_) {}));
      await subs.cancelAll();
      await subs.cancelAll();
      expect(c.hasListener, isFalse);
      addTearDown(() async => c.close());
    });
  });
}
