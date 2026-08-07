import 'dart:typed_data';

final class FWMapRequestData {
  final int windowIncrement;
  final int firmwareToErase;
  final int firmwareToMap;
  final Uint8List error;

  FWMapRequestData({
    required this.windowIncrement,
    required this.firmwareToErase,
    required this.firmwareToMap,
    required this.error,
  });

  factory FWMapRequestData.from(ByteData data) {
    final int window = data.getInt16(0);
    final int firmwareToErase = data.getInt8(2);
    final int erase = data.getInt8(3);
    final int errorHi = data.getInt8(4);
    final int errorMid = data.getInt8(5);
    final int errorLow = data.getInt8(6);

    return FWMapRequestData(
      windowIncrement: window,
      firmwareToErase: firmwareToErase,
      firmwareToMap: erase,
      error: Uint8List.fromList([errorHi, errorMid, errorLow]),
    );
  }

  ByteData asData() {
    final data = ByteData(7);
    data.setInt16(0, windowIncrement);
    data.setInt8(2, firmwareToErase);
    data.setInt8(3, firmwareToMap);
    data.setInt8(4, error[0]);
    data.setInt8(5, error[1]);
    data.setInt8(6, error[2]);
    return data;
  }
}

Uint8List encodeU24P0(int value) {
  if (value < 0 || value > 0xFFFFFF) {
    throw ArgumentError(
      'Value must be between 0 and 0xFFFFFF (24-bit unsigned)',
    );
  }
  return Uint8List.fromList([
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);
}
