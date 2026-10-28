import 'dart:typed_data';

import 'package:reaprime/src/models/device/de1_interface.dart';

/// A012 calibration characteristic packet codec, mirroring the DE1
/// firmware's `T_Calibration` struct (`BLE/DE1_BLE/src/APIDataTypes.hpp`)
/// and de1app's `calibrate_spec` (`de1plus/binary.tcl`).
///
/// Wire layout (14 bytes, big-endian):
///   WriteKey       UInt32  - 1 for reads, 0xCAFEF00D for writes
///   CalCommand     UInt8   - 0 current read, 1 write, 2 reset, 3 factory read
///   CalTarget      UInt8   - 0 flow, 1 pressure, 2 temperature
///   DE1ReportedVal S32P16  - Q16.16 fixed point, signed
///   MeasuredVal    S32P16  - Q16.16 fixed point, signed
final class De1CalibrationCodec {
  static const int packetLength = 14;

  static const int readCommand = 0;
  static const int writeCommand = 1;
  static const int factoryReadCommand = 3;

  static const int _readWriteKey = 1;
  static const int _writeWriteKey = 0xCAFEF00D;

  /// Signed Q16.16 representable range (S32P16).
  static const double minValue = De1Calibration.minValue;
  static const double maxValueExclusive = De1Calibration.maxValueExclusive;

  static Uint8List encodeRead(
    De1CalibrationTarget target, {
    required bool factory,
  }) {
    final bytes = ByteData(packetLength);
    bytes.setUint32(0, _readWriteKey, Endian.big);
    bytes.setUint8(4, factory ? factoryReadCommand : readCommand);
    bytes.setUint8(5, target.wireValue);
    bytes.setUint32(6, 0, Endian.big);
    bytes.setInt32(10, 0, Endian.big);
    return bytes.buffer.asUint8List();
  }

  static Uint8List encodeWrite(De1Calibration calibration) {
    calibration.validateForWrite();
    final reported = _encodeQ16_16Signed(calibration.de1ReportedValue);
    final measured = _encodeQ16_16Signed(calibration.measuredValue);
    final bytes = ByteData(packetLength);
    bytes.setUint32(0, _writeWriteKey, Endian.big);
    bytes.setUint8(4, writeCommand);
    bytes.setUint8(5, calibration.target.wireValue);
    bytes.setInt32(6, reported, Endian.big);
    bytes.setInt32(10, measured, Endian.big);
    return bytes.buffer.asUint8List();
  }

  static De1CalibrationPacket decode(Uint8List bytes) {
    if (bytes.length < packetLength) {
      throw FormatException(
        'Calibration packet too short (${bytes.length} < $packetLength bytes)',
      );
    }
    final data = ByteData.sublistView(bytes);
    final target = De1CalibrationTarget.fromWireValue(data.getUint8(5));
    if (target == null) {
      throw FormatException('Unknown calibration target ${data.getUint8(5)}');
    }
    return De1CalibrationPacket(
      writeKey: data.getUint32(0, Endian.big),
      command: data.getUint8(4),
      target: target,
      de1ReportedValue: _decodeQ16_16Signed(data.getInt32(6, Endian.big)),
      measuredValue: _decodeQ16_16Signed(data.getInt32(10, Endian.big)),
    );
  }

  static De1CalibrationPacket? tryDecode(Uint8List bytes) {
    try {
      return decode(bytes);
    } on FormatException {
      return null;
    }
  }

  static int _encodeQ16_16Signed(double value) =>
      (value * De1Calibration.fixedPointScale).round();

  static double _decodeQ16_16Signed(int raw) =>
      raw / De1Calibration.fixedPointScale;
}

final class De1CalibrationPacket {
  final int writeKey;
  final int command;
  final De1CalibrationTarget target;
  final double de1ReportedValue;
  final double measuredValue;

  const De1CalibrationPacket({
    required this.writeKey,
    required this.command,
    required this.target,
    required this.de1ReportedValue,
    required this.measuredValue,
  });

  bool get isReturnedData => writeKey == 0;

  bool matches(int command, De1CalibrationTarget target) =>
      this.command == command && this.target == target;
}
