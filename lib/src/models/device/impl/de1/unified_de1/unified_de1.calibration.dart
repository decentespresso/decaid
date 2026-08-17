part of 'unified_de1.dart';

extension UnifiedDe1Calibration on UnifiedDe1 {
  Future<De1CalibrationPacket> _calibrationRequest(
    Uint8List payload, {
    required int command,
    required De1CalibrationTarget target,
    required bool expectReturnedData,
  }) {
    final completer = Completer<De1CalibrationPacket>();
    _calibrationQueue = _calibrationQueue.then((_) async {
      try {
        final response = _transport.calibration
            .map((d) => De1CalibrationCodec.tryDecode(d.buffer.asUint8List()))
            .where(
              (packet) =>
                  packet != null &&
                  packet.matches(command, target) &&
                  packet.isReturnedData == expectReturnedData,
            )
            .first
            .timeout(calibrationTimeout, onTimeout: () => null)
            .catchError(
              (Object error) => null,
              test: (Object error) => error is StateError,
            );
        await _transport.writeWithResponse(Endpoint.calibration, payload);
        final packet = await response;
        if (packet == null) {
          throw EndpointUnavailableException('calibration', calibrationTimeout);
        }
        completer.complete(packet);
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }
}
