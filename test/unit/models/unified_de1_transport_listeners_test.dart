import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';

import '../../helpers/fake_ble_transport.dart';

void main() {
  test('one-shot settings reads release the source subject', () async {
    final transport = UnifiedDe1Transport(transport: FakeBleTransport());
    addTearDown(transport.dispose);
    await transport.connect();

    for (var i = 0; i < 3; i++) {
      await transport.shotSettings.first;
      expect(transport.debugHasShotSettingsListener, isFalse);
    }
  });

  test('cancelled calibration listeners release the source subject', () async {
    final transport = UnifiedDe1Transport(transport: FakeBleTransport());
    addTearDown(transport.dispose);

    for (var i = 0; i < 3; i++) {
      final subscription = transport.calibration.listen((_) {});
      await subscription.cancel();
      expect(transport.debugHasCalibrationListener, isFalse);
    }
  });
}
