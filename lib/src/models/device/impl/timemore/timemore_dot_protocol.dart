import 'dart:typed_data';

final class TimemoreDotFrame {
  const TimemoreDotFrame({
    required this.opcode,
    required this.cmdId,
    required this.payload,
  });

  final int opcode;
  final int cmdId;
  final Uint8List payload;
}

final class TimemoreDotProtocol {
  static const int magicFirst = 0xA5;
  static const int magicSecond = 0x5A;
  static const int headerSize = 6;
  static const int crcSize = 2;
  static const int maxPayloadLength = 64;
  static const int frameOverhead = headerSize + crcSize;

  static Uint8List buildFrame(int opcode, int cmdId, List<int> payload) {
    if (payload.length > maxPayloadLength) {
      throw ArgumentError('Dot frame payload exceeds $maxPayloadLength bytes');
    }
    final body = Uint8List.fromList([
      magicFirst,
      magicSecond,
      opcode,
      cmdId,
      (payload.length >> 8) & 0xFF,
      payload.length & 0xFF,
      ...payload,
    ]);
    final crc = crc16Ibm(body);
    return Uint8List.fromList([...body, (crc >> 8) & 0xFF, crc & 0xFF]);
  }

  static int crc16Ibm(List<int> data) {
    var crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return crc & 0xFFFF;
  }

  static bool isValidFrame(List<int> bytes) {
    if (bytes.length < frameOverhead) return false;
    if (bytes[0] != magicFirst || bytes[1] != magicSecond) return false;
    final payloadLength = (bytes[4] << 8) | bytes[5];
    if (payloadLength > maxPayloadLength) return false;
    if (bytes.length != payloadLength + frameOverhead) return false;
    final actual = (bytes[bytes.length - 2] << 8) | bytes[bytes.length - 1];
    return crc16Ibm(bytes.sublist(0, bytes.length - crcSize)) == actual;
  }

  static bool isWellFormedFrame(List<int> bytes) {
    if (bytes.length < frameOverhead) return false;
    if (bytes[0] != magicFirst || bytes[1] != magicSecond) return false;
    final payloadLength = (bytes[4] << 8) | bytes[5];
    if (payloadLength > maxPayloadLength) return false;
    return bytes.length == payloadLength + frameOverhead;
  }

  static TimemoreDotFrame parseFrame(List<int> bytes) {
    if (!isWellFormedFrame(bytes)) {
      throw const FormatException('invalid Timemore Dot frame');
    }
    return TimemoreDotFrame(
      opcode: bytes[2],
      cmdId: bytes[3],
      payload: Uint8List.fromList(
        bytes.sublist(headerSize, bytes.length - crcSize),
      ),
    );
  }

  static Uint8List tareCommand() => buildFrame(0x03, 0x0D, const []);
  static Uint8List timerStartCommand() => buildFrame(0x03, 0x02, const [0x01]);
  static Uint8List timerStopCommand() => buildFrame(0x03, 0x02, const [0x02]);
  static Uint8List timerResetCommand() => buildFrame(0x03, 0x02, const [0x03]);
  static Uint8List initUnitCommand() => buildFrame(0x03, 0x06, const [0x00]);
  static Uint8List initModeCommand() =>
      buildFrame(0x03, 0x08, const [0x01, 0x00]);
  static Uint8List initBatteryCommand() => buildFrame(0x02, 0x05, const []);
}
