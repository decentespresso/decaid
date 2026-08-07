import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/machine.dart';

void main() {
  group('De1StateEnum.fwUpgrade', () {
    test('fwUpgrade encodes as 0x16 on the wire', () {
      expect(De1StateEnum.fwUpgrade.hexValue, 0x16);
    });

    test('fromHexValue(0x16) decodes to fwUpgrade (readback works)', () {
      expect(De1StateEnum.fromHexValue(0x16), De1StateEnum.fwUpgrade);
    });

    test('fromMachineState(fwUpgrade) round-trips to the 0x16 wire byte', () {
      final state = De1StateEnum.fromMachineState(MachineState.fwUpgrade);
      expect(state, De1StateEnum.fwUpgrade);
      expect(state.hexValue, 0x16);
    });
  });
}
