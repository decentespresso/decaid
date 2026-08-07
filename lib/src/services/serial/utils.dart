import 'dart:typed_data';

import 'package:logging/logging.dart';

final _log = Logger('SerialUtils');

// ---- Device-specific detection helpers ----
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

/// Non-blocking replacement for the native `sp_drain`, which has no timeout
/// and blocks the calling isolate forever when a USB-serial device never
/// transmits the buffered bytes (observed when scan probes a non-Decent
/// device, e.g. a Valve VR Radio on a Windows COM port — it froze startup).
///
/// Polls [bytesToWrite] until it reports an empty output buffer or [timeout]
/// elapses, sleeping [pollInterval] between reads. Always returns; never
/// waits longer than `ceil(timeout / pollInterval)` polls. [sleep] is
/// injectable for tests.
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

/// Build a stable device ID for HDS from USB metadata.
/// Returns null if vid or pid are missing (can't form a meaningful ID).
String? computeUsbStableId({int? vid, int? pid, String? serial}) {
  if (vid == null || pid == null) return null;
  final s = (serial != null && serial.isNotEmpty) ? serial : 'unknown';
  return 'usb-${vid.toRadixString(16)}-${pid.toRadixString(16)}-$s';
}
