import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';

import '../../helpers/fake_ble_transport.dart';

/// The BengleEstSample subscribe must be conditional on BLE. A CCCD write
/// against a characteristic the peripheral never registered stalls the command
/// queue, so firmware predating the GATT registration must be left alone.
void main() {
  group('estimator subscribe over BLE', () {
    test(
      'is SKIPPED when the machine does not expose the characteristic',
      () async {
        final transport = FakeBleTransport();
        // Firmware without the estimator characteristic registered.
        transport.presentCharacteristics = const [];
        final de1 = UnifiedDe1Transport(transport: transport);

        final subscribed = await de1.subscribeEstimator();

        expect(subscribed, isFalse);
        expect(
          transport.subscribers.containsKey(Endpoint.estimator.uuid),
          isFalse,
          reason: 'a blind CCCD write here would stall the command queue',
        );
        await transport.dispose();
      },
    );

    test('subscribes when the machine does expose it', () async {
      final transport = FakeBleTransport();
      transport.presentCharacteristics = [Endpoint.estimator.uuid];
      final de1 = UnifiedDe1Transport(transport: transport);

      final subscribed = await de1.subscribeEstimator();

      expect(subscribed, isTrue);
      expect(
        transport.subscribers.containsKey(Endpoint.estimator.uuid),
        isTrue,
      );
      await transport.dispose();
    });

    test('presence matching is case-insensitive', () async {
      final transport = FakeBleTransport();
      transport.presentCharacteristics = [
        Endpoint.estimator.uuid.toUpperCase(),
      ];
      final de1 = UnifiedDe1Transport(transport: transport);

      expect(await de1.subscribeEstimator(), isTrue);
      await transport.dispose();
    });
  });
}
