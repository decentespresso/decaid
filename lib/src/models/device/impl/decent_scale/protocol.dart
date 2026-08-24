import 'dart:typed_data';

Uint8List buildDecentScaleCommand(List<int> commandBytes) {
  final bytes = <int>[0x03, ...commandBytes];
  final checksum = bytes.fold(0, (value, byte) => value ^ byte);
  return Uint8List.fromList([...bytes, checksum]);
}
