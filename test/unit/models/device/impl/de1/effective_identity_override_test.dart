import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../../../../helpers/fake_ble_transport.dart';

void main() {
  test(
    'applyEffectiveIdentity changes only serial/model and never writes MMR',
    () async {
      final transport = FakeBleTransport()
        ..queueOnConnectResponses(
          v13Model: 3,
          ghcInfo: 0x04,
          serialN: 0,
          cpuFirmwareBuild: 1300,
          heaterV: 230,
          refillKitPresent: 1,
        );
      final de1 = UnifiedDe1(transport: transport);

      await de1.onConnect();

      final raw = de1.machineInfo;
      expect(raw.serialNumber, '0');
      expect(raw.model, DecentMachineModel.DE1Pro.name);
      expect(raw.version, '1300');
      expect(raw.groupHeadControllerPresent, isTrue);
      expect(raw.extra['voltage'], 230);
      expect(de1.rawModelValue, 3);

      final writesBefore = transport.writes.length;

      de1.applyEffectiveIdentity(
        serial: '1338',
        model: DecentMachineModel.DE1XL.name,
      );

      expect(transport.writes.length, writesBefore, reason: 'no MMR write');

      final effective = de1.machineInfo;
      expect(effective.serialNumber, '1338');
      expect(effective.model, DecentMachineModel.DE1XL.name);
      expect(effective.version, raw.version);
      expect(effective.groupHeadControllerPresent, isTrue);
      expect(effective.extra, raw.extra);
      expect(effective.toJson()['GHC'], isTrue);

      // Raw identity retained for diagnostics and matching.
      expect(de1.rawMachineInfo.serialNumber, '0');
      expect(de1.rawMachineInfo.model, DecentMachineModel.DE1Pro.name);

      await de1.onConnect();

      expect(de1.machineInfo.serialNumber, '0');
      expect(de1.machineInfo.model, DecentMachineModel.DE1Pro.name);

      await transport.dispose();
    },
  );
}
