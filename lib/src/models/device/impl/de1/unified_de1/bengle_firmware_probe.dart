part of 'unified_de1.dart';

// One-shot, per-connection firmware compatibility check; see
// doc/AI_BENGLE_NOTES.md.
mixin BengleFirmwareProbe on UnifiedDe1 {
  static const _defaultProbeTimeout = Duration(seconds: 2);
  static const _probeAttempts = 2;

  bool _bengleProbeDone = false;
  bool _supportsCurrentBengleFirmwareSurface = false;
  Future<bool>? _probeInFlight;

  @override
  bool get supportsCurrentBengleFirmwareSurface =>
      _supportsCurrentBengleFirmwareSurface;

  Future<bool> probeBengleFirmwareSurface() {
    if (_bengleProbeDone) {
      return Future.value(_supportsCurrentBengleFirmwareSurface);
    }
    return _probeInFlight ??= _runProbe();
  }

  Future<bool> _runProbe() async {
    _bengleProbeDone = true;
    await _firmwareMmrGate.runMmr(() async {
      for (var attempt = 1; attempt <= _probeAttempts; attempt++) {
        try {
          final bytes = ByteData(20)
            ..setInt32(0, BengleMmr.scaleCalWeight.address, Endian.big);
          final buffer = bytes.buffer.asUint8List();

          final responseFuture = _mmr
              .map((d) => d.buffer.asUint8List().toList())
              .firstWhere(
                (element) =>
                    buffer[1] == element[1] &&
                    buffer[2] == element[2] &&
                    buffer[3] == element[3],
                orElse: () => <int>[],
              )
              .timeout(_defaultProbeTimeout, onTimeout: () => <int>[]);

          await _transport.writeWithResponse(
            Endpoint.readFromMMR,
            Uint8List.fromList(buffer),
          );
          final result = await responseFuture;
          if (result.isNotEmpty) {
            _supportsCurrentBengleFirmwareSurface = true;
            _log.info('Bengle firmware surface probe: current firmware');
            return;
          }
          _log.warning(
            'Bengle firmware surface probe attempt $attempt timed out '
            '(firmware may predate the 0x00803880 MMR surface)',
          );
        } catch (e) {
          _log.warning(
            'Bengle firmware surface probe attempt $attempt failed: $e',
          );
        }
      }
      _supportsCurrentBengleFirmwareSurface = false;
      _log.info(
        'Bengle firmware surface probe: OUTDATED firmware (predates the '
        '0x00803880 MMR surface); Bengle features unavailable',
      );
    });
    return _supportsCurrentBengleFirmwareSurface;
  }
}
