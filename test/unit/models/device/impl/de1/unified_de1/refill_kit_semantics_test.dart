import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

void main() {
  group('refill kit detection vs configuration', () {
    late FakeBleTransport transport;
    late UnifiedDe1 de1;

    Future<void> connect({required int detected}) async {
      transport.queueOnConnectResponses(refillKitPresent: detected);
      await de1.onConnect();
    }

    setUp(() {
      transport = FakeBleTransport();
      de1 = UnifiedDe1(transport: transport);
    });

    tearDown(() => transport.dispose());

    test(
      'a detected kit is published as machineInfo.extra.refillKit',
      () async {
        await connect(detected: 1);
        expect(de1.machineInfo.extra['refillKit'], isTrue);
      },
    );

    test(
      'connect leaves the configuration at auto, not at the detected value',
      () async {
        await connect(detected: 1);
        expect(
          await de1.getRefillKitSettings(),
          De1RefillKitSettings.auto,
          reason:
              'onConnect writes 0x02 to the register, so auto is what is set; '
              'reporting forceOn here would be the detected value leaking out',
        );
      },
    );

    test('writing forceOff does not disturb the detected state', () async {
      await connect(detected: 1);
      await de1.setRefillKitSettings(De1RefillKitSettings.forceOff);

      expect(await de1.getRefillKitSettings(), De1RefillKitSettings.forceOff);
      expect(de1.machineInfo.extra['refillKit'], isTrue);
    });

    test('writing forceOn does not invent a detection', () async {
      await connect(detected: 0);
      await de1.setRefillKitSettings(De1RefillKitSettings.forceOn);

      expect(await de1.getRefillKitSettings(), De1RefillKitSettings.forceOn);
      expect(de1.machineInfo.extra['refillKit'], isFalse);
    });

    test('detection masks bit 0 while the configuration stays auto', () async {
      await connect(detected: 0x81);

      expect(de1.machineInfo.extra['refillKit'], isTrue);
      expect(
        await de1.getRefillKitSettings(),
        De1RefillKitSettings.auto,
        reason: 'a raw register value must never be parsed as a configuration',
      );
    });

    test(
      'the override survives a reconnect of the same device object',
      () async {
        await connect(detected: 1);
        await de1.setRefillKitSettings(De1RefillKitSettings.forceOff);

        await de1.onConnect();

        expect(
          await de1.getRefillKitSettings(),
          De1RefillKitSettings.forceOff,
          reason:
              'onConnect returns early once _info is set, so no MMR write of '
              'auto happens on a second connect of the same instance',
        );
      },
    );

    test('a freshly discovered device starts from auto again', () async {
      await connect(detected: 1);
      await de1.setRefillKitSettings(De1RefillKitSettings.forceOff);

      final transport2 = FakeBleTransport();
      addTearDown(transport2.dispose);
      final de1b = UnifiedDe1(transport: transport2);
      transport2.queueOnConnectResponses(refillKitPresent: 1);
      await de1b.onConnect();

      expect(await de1b.getRefillKitSettings(), De1RefillKitSettings.auto);
      expect(de1b.machineInfo.extra['refillKit'], isTrue);
    });

    test('the connect-time write puts auto on the wire', () async {
      await connect(detected: 1);

      final addr = MMRItem.refillKitPresent.address;
      final writes = transport.writes.where(
        (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
      );
      final refillWrites = writes.where((w) {
        return w.data.length >= 5 &&
            w.data[1] == (addr >> 16) & 0xFF &&
            w.data[2] == (addr >> 8) & 0xFF &&
            w.data[3] == addr & 0xFF;
      }).toList();

      expect(refillWrites, hasLength(1));
      expect(refillWrites.single.data[4], 0x02);
    });
  });
}
