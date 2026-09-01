import 'dart:typed_data';

import 'package:logging/logging.dart';

final _log = Logger('SerialUtils');

final _hdsRegex = RegExp(r'\d+ Weight: .*');
bool isDecentScale(List<String> messages, List<Uint8List> captures) {
  _log.finer("is HDS: checking ${messages.length}, $messages");
  return captures.any(
        (Uint8List bytes) =>
            bytes.length > 5 &&
            bytes[0] == 0x03 &&
            bytes[1] == 0xCE &&
            bytes[4] == 0 &&
            bytes[5] == 0,
      ) ||
      messages.any((t) => _hdsRegex.hasMatch(t));
}

final _sbRegex = RegExp(
  r'^\d+ (?:nan|[+-]?[0-9]*[.]?[0-9]+) [+-]?[0-9]*[.]?[0-9]+ [+-]?[0-9]*[.]?[0-9]+ [+-]?[0-9]*[.]?[0-9]+',
);
bool isSensorBasket(List<String> messages) {
  return messages.any((t) => _sbRegex.hasMatch(t));
}

bool isDE1(List<String> data, List<int> bytes) {
  _log.finer("figuring out $data");
  return data.any((e) => e.startsWith("[M]"));
}

bool serialProbeAllowsProductName(String? productName) {
  if (productName == null || productName.contains('Serial')) return true;
  return const {'DE1', 'Bengle', 'Half Decent Scale'}.contains(productName);
}

Future<void> drainWithTimeout({
  required int Function() bytesToWrite,
  Duration timeout = const Duration(milliseconds: 200),
  Duration pollInterval = const Duration(milliseconds: 5),
  Future<void> Function(Duration)? sleep,
}) async {
  final sleepFn = sleep ?? Future<void>.delayed;
  final maxPolls = pollInterval.inMicroseconds <= 0
      ? 0
      : (timeout.inMicroseconds / pollInterval.inMicroseconds).ceil();
  for (var i = 0; i < maxPolls; i++) {
    if (bytesToWrite() <= 0) return;
    await sleepFn(pollInterval);
  }
}

String? computeUsbStableId({
  int? vid,
  int? pid,
  String? serial,
  int? interfaceNumber,
}) {
  if (vid == null || pid == null) return null;
  final s = (serial != null && serial.isNotEmpty) ? serial : 'unknown';
  final id = 'usb-${vid.toRadixString(16)}-${pid.toRadixString(16)}-$s';
  if (interfaceNumber == null || interfaceNumber <= 0) return id;
  return '$id-if${interfaceNumber.toRadixString(16).padLeft(2, '0')}';
}

/// Strips a trailing `-ifNN` (optionally followed by a physical-instance
/// `-<deviceId>`) suffix from a USB stable ID, so a composite device's
/// machine and tap logical IDs map back to one physical device. IDs without
/// a suffix are returned unchanged.
String withoutUsbInterfaceSuffix(String stableId) {
  final match = RegExp(r'-if[0-9a-fA-F]+(?:-[0-9]+)?$').firstMatch(stableId);
  return match == null ? stableId : stableId.substring(0, match.start);
}
