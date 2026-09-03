import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/timemore/timemore_dot_protocol.dart';

void main() {
  group('TimemoreDotProtocol', () {
    test(
      'builds all commands byte-identical to the verified reference frames',
      () {
        expect(
          TimemoreDotProtocol.tareCommand(),
          Uint8List.fromList([0xA5, 0x5A, 0x03, 0x0D, 0x00, 0x00, 0x64, 0xD1]),
        );
        expect(
          TimemoreDotProtocol.timerStartCommand(),
          Uint8List.fromList([
            0xA5,
            0x5A,
            0x03,
            0x02,
            0x00,
            0x01,
            0x01,
            0x18,
            0x67,
          ]),
        );
        expect(
          TimemoreDotProtocol.timerStopCommand(),
          Uint8List.fromList([
            0xA5,
            0x5A,
            0x03,
            0x02,
            0x00,
            0x01,
            0x02,
            0x19,
            0x27,
          ]),
        );
        expect(
          TimemoreDotProtocol.timerResetCommand(),
          Uint8List.fromList([
            0xA5,
            0x5A,
            0x03,
            0x02,
            0x00,
            0x01,
            0x03,
            0xD9,
            0xE6,
          ]),
        );
        expect(
          TimemoreDotProtocol.initUnitCommand(),
          Uint8List.fromList([
            0xA5,
            0x5A,
            0x03,
            0x06,
            0x00,
            0x01,
            0x00,
            0xE8,
            0xA7,
          ]),
        );
        expect(
          TimemoreDotProtocol.initModeCommand(),
          Uint8List.fromList([
            0xA5,
            0x5A,
            0x03,
            0x08,
            0x00,
            0x02,
            0x01,
            0x00,
            0xEB,
            0x31,
          ]),
        );
        expect(
          TimemoreDotProtocol.initBatteryCommand(),
          Uint8List.fromList([0xA5, 0x5A, 0x02, 0x05, 0x00, 0x00, 0x5A, 0x51]),
        );
      },
    );

    test('crc16Ibm is the Modbus variant with init 0xFFFF', () {
      expect(
        TimemoreDotProtocol.crc16Ibm([0xA5, 0x5A, 0x03, 0x0D, 0x00, 0x00]),
        0x64D1,
      );
    });

    test('buildFrame rejects payloads over the maximum', () {
      expect(
        () => TimemoreDotProtocol.buildFrame(0x01, 0x01, List.filled(65, 0)),
        throwsArgumentError,
      );
    });

    test('isValidFrame rejects short frames, bad magic, and bad CRC', () {
      final valid = TimemoreDotProtocol.buildFrame(0x01, 0x01, const [0x01]);
      expect(TimemoreDotProtocol.isValidFrame(valid), isTrue);
      expect(TimemoreDotProtocol.isValidFrame(valid.sublist(0, 7)), isFalse);
      final badMagic = Uint8List.fromList(valid);
      badMagic[0] = 0x00;
      expect(TimemoreDotProtocol.isValidFrame(badMagic), isFalse);
      final badCrc = Uint8List.fromList(valid);
      badCrc[badCrc.length - 1] ^= 0xFF;
      expect(TimemoreDotProtocol.isValidFrame(badCrc), isFalse);
      final wrongLength = Uint8List.fromList([...valid, 0x00]);
      expect(TimemoreDotProtocol.isValidFrame(wrongLength), isFalse);
    });

    test('parseFrame extracts opcode, cmdId, and payload', () {
      final frame = TimemoreDotProtocol.parseFrame(
        TimemoreDotProtocol.buildFrame(0x01, 0x01, const [
          0x00,
          0x00,
          0x30,
          0x39,
          0x00,
          0x00,
          0x00,
          0x2A,
          0x00,
        ]),
      );
      expect(frame.opcode, 0x01);
      expect(frame.cmdId, 0x01);
      expect(
        frame.payload,
        Uint8List.fromList(const [
          0x00,
          0x00,
          0x30,
          0x39,
          0x00,
          0x00,
          0x00,
          0x2A,
          0x00,
        ]),
      );
    });

    test('parseFrame throws FormatException on invalid input', () {
      expect(
        () => TimemoreDotProtocol.parseFrame(Uint8List.fromList([0x00])),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
