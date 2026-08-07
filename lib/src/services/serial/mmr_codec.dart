import 'dart:typed_data';

Uint8List buildMmrReadRequest({required int address, required int length}) {
  final bytes = ByteData(20);
  bytes.setInt32(0, address, Endian.big);
  final buf = bytes.buffer.asUint8List();
  buf[0] = length & 0xFF;
  return buf;
}

int? decodeMmrInt32Response(
  String line, {
  required (int, int, int) expectedAddr,
}) {
  if (!line.startsWith('[E]')) return null;
  final hex = line.substring(3);
  final bytes = _tryParseHex(hex);
  if (bytes == null) return null;
  if (bytes.length < 8) return null;
  if (bytes[1] != expectedAddr.$1 ||
      bytes[2] != expectedAddr.$2 ||
      bytes[3] != expectedAddr.$3) {
    return null;
  }
  final view = ByteData.sublistView(Uint8List.fromList(bytes));
  return view.getInt32(4, Endian.little);
}

Uint8List? _tryParseHex(String hex) {
  if (hex.length.isOdd) return null;
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < hex.length; i += 2) {
    final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (b == null) return null;
    out[i ~/ 2] = b;
  }
  return out;
}
