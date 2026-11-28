part of 'unified_de1.dart';

extension UnifiedDe1Calibration on UnifiedDe1 {
  Future<De1CalibrationPacket> _calibrationRequest(
    Uint8List payload, {
    required int command,
    required De1CalibrationTarget target,
  }) {
    final completer = Completer<De1CalibrationPacket>();
    _calibrationQueue = _calibrationQueue.then((_) async {
      try {
        completer.complete(
          await _readCalibrationResponse(payload, command, target),
        );
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }

  Future<De1CalibrationPacket> _readCalibrationResponse(
    Uint8List payload,
    int command,
    De1CalibrationTarget target,
  ) async {
    final response = StreamIterator(
      _transport.calibration
          .map(
            (data) => De1CalibrationCodec.tryDecode(data.buffer.asUint8List()),
          )
          .where(
            (packet) =>
                packet != null &&
                packet.matches(command, target) &&
                packet.isReturnedData,
          ),
    );
    final received = response.moveNext().timeout(
      calibrationTimeout,
      onTimeout: () async {
        await response.cancel();
        return false;
      },
    );
    received.ignore();
    try {
      await _transport.writeWithResponse(Endpoint.calibration, payload);
      if (!await received) {
        throw EndpointUnavailableException('calibration', calibrationTimeout);
      }
      return response.current!;
    } finally {
      await response.cancel();
    }
  }
}
