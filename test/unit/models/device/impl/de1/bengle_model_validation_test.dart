import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../../../../helpers/fake_ble_transport.dart';

void main() {
  test('maps the Bengle model family without changing DE1 mappings', () {
    expect(isBengleModelValue(127), isFalse);
    for (final value in [128, 129, 255]) {
      expect(isBengleModelValue(value), isTrue);
      expect(DecentMachineModel.fromInt(value), DecentMachineModel.Bengle);
    }
    expect(DecentMachineModel.fromInt(0), DecentMachineModel.Unknown);
    expect(DecentMachineModel.fromInt(1), DecentMachineModel.DE1);
    expect(DecentMachineModel.fromInt(2), DecentMachineModel.DE1Plus);
    expect(DecentMachineModel.fromInt(3), DecentMachineModel.DE1Pro);
    expect(DecentMachineModel.fromInt(4), DecentMachineModel.DE1XL);
    expect(DecentMachineModel.fromInt(5), DecentMachineModel.DE1Cafe);
    expect(DecentMachineModel.fromInt(6), DecentMachineModel.DE1XXL);
    expect(DecentMachineModel.fromInt(7), DecentMachineModel.DE1XXXL);
    expect(DecentMachineModel.fromInt(127), DecentMachineModel.Unknown);
  });

  test('UnifiedDe1 warns but connects to a Bengle model', () async {
    final transport = FakeBleTransport()
      ..queueOnConnectResponses(v13Model: 129);
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord.listen(records.add);
    final de1 = UnifiedDe1(transport: transport);

    await de1.onConnect();

    expect(de1.machineInfo.model, DecentMachineModel.Bengle.name);
    expect(
      records.any(
        (record) => record.message.toString().contains(
          'continuing in degraded DE1-compatible mode',
        ),
      ),
      isTrue,
    );
    await subscription.cancel();
    await transport.dispose();
  });

  test(
    'Bengle rejects a stock DE1 model before capability initialization',
    () async {
      final transport = FakeBleTransport()
        ..queueOnConnectResponses(v13Model: 3);
      final bengle = Bengle(transport: transport);

      await expectLater(
        bengle.onConnect(),
        throwsA(
          isA<DeviceIdentityMismatchException>().having(
            (e) => e.actualModelValue,
            'actualModelValue',
            3,
          ),
        ),
      );
      await transport.dispose();
    },
  );

  test('Bengle initializes normally for the Bengle model family', () async {
    final transport = FakeBleTransport()
      ..queueOnConnectResponses(v13Model: 129)
      ..queuePaletteHydrationResponses();
    final bengle = Bengle(transport: transport);

    await bengle.onConnect();

    expect(bengle.machineInfo.model, DecentMachineModel.Bengle.name);
    await transport.dispose();
  });
}
