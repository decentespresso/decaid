import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/models/device/impl/mock_scale/mock_scale.dart';
import 'package:reaprime/src/models/device/scale.dart';

void main() {
  test(
    'released MockScale emits through repeated auxiliary sessions',
    () async {
      final scale = MockScale();
      final registry = AuxiliaryScaleRegistry();
      addTearDown(() async {
        await registry.dispose();
        await scale.disconnect();
      });

      await scale.onConnect();
      await scale.currentSnapshot.first.timeout(const Duration(seconds: 2));
      await scale.disconnect();

      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await registry.connect(
          scale,
          isPrimaryClaimed: (_) => false,
        );
        expect(result.success, isTrue);
        final session = registry.connectionFor(scale.deviceId)!;
        expect(
          await session.snapshots.first.timeout(const Duration(seconds: 2)),
          isA<ScaleSnapshot>(),
        );
        expect((await registry.disconnect(scale.deviceId)).success, isTrue);
        expect(registry.connectionFor(scale.deviceId), isNull);
      }
    },
  );
}
