List<int> bookooPacket(double grams, {int? battery = 50}) {
  final magnitude = (grams.abs() * 100).round();
  final packet = List<int>.filled(20, 0);
  packet[0] = 0x03;
  packet[1] = 0x0B;
  packet[6] = grams < 0 ? 0x2D : 0x2B;
  packet[7] = (magnitude >> 16) & 0xff;
  packet[8] = (magnitude >> 8) & 0xff;
  packet[9] = magnitude & 0xff;
  if (battery != null) packet[13] = battery;
  packet[19] = packet.take(19).fold(0, (sum, byte) => sum ^ byte);
  return packet;
}

const bookooCommands = [
  [0x03, 0x0A, 0x01, 0, 0, 0x08],
  [0x03, 0x0A, 0x04, 0, 0, 0x0D],
  [0x03, 0x0A, 0x05, 0, 0, 0x0C],
  [0x03, 0x0A, 0x06, 0, 0, 0x0F],
];

List<List<int>> invalidBookooPackets() {
  final valid = bookooPacket(10);
  final sign = [...valid];
  sign[6] = 0;
  sign[19] = sign.take(19).fold(0, (sum, byte) => sum ^ byte);
  return [
    for (final length in [0, 9, 10, 11, 19]) valid.sublist(0, length),
    [...valid, 0],
    [0x04, ...valid.sublist(1)],
    [0x03, 0x0A, ...valid.sublist(2)],
    [...valid.take(19), valid.last ^ 1],
    sign,
  ];
}
