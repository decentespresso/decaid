/// ROT13 encode/decode.
///
/// ROT13 is a Caesar cipher rotating [A-Za-z] by 13 positions.
/// It is self-inverse — the same function both encodes and decodes.
/// Non-alpha characters pass through unchanged.
String rot13(String input) {
  final buf = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    buf.writeCharCode(_rotate(input.codeUnitAt(i)));
  }
  return buf.toString();
}

int _rotate(int c) {
  if (c >= 65 && c <= 90) {
    return ((c - 65 + 13) % 26) + 65;
  }
  if (c >= 97 && c <= 122) {
    return ((c - 97 + 13) % 26) + 97;
  }
  return c;
}
