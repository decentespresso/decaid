part of 'unified_de1.dart';

/// One-shot, per-connection feature detection for the Bengle firmware
/// surface added after MMR.def rows 0-38 (the original shipped map).
///
/// There is no reliable build-number mapping in the Bengle repo:
/// `CPUFirmwareBuild` is stamped into the image at flash time
/// (makeheaderedbinfile.py reads it back from offset 0xD0), so the plan's
/// preferred build gate is not constructible. On firmware without rows 39+
/// (scale cal, LED palette, cup warmer, schedule, pre-warm), reads of those
/// addresses are flushed by APIView with NO response, so a read of
/// `ScaleCalWeight` (row 41) either answers (new firmware) or times out
/// (old firmware). One bounded attempt per connection, latched; never
/// repeated by polled endpoints.
mixin BengleFirmwareProbe on UnifiedDe1 {
  static const _defaultProbeTimeout = Duration(seconds: 2);

  bool _bengleProbeDone = false;
  bool _bengleFeatureSurfaceSupported = false;

  /// True when the connected machine implements the post-0x00803880 Bengle
  /// MMR surface. False on old firmware (and, by default, on non-Bengle
  /// machines, which never call [probeBengleFirmwareSurface]).
  bool get bengleFeatureSurfaceSupported => _bengleFeatureSurfaceSupported;

  /// Single bounded probe: one read of `ScaleCalWeight`, no retries. Any
  /// response (even zero) proves the register exists; a timeout proves it
  /// does not. Safe to call repeatedly; only the first call reads.
  Future<bool> probeBengleFirmwareSurface() async {
    if (_bengleProbeDone) return _bengleFeatureSurfaceSupported;
    _bengleProbeDone = true;
    await _firmwareMmrGate.runMmr(() async {
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
        _bengleFeatureSurfaceSupported = result.isNotEmpty;
        _log.info(
          'Bengle firmware surface probe: '
          '${_bengleFeatureSurfaceSupported ? 'supported' : 'NOT supported '
                    '(firmware predates the 0x00803880 MMR surface)'}',
        );
      } catch (e) {
        _log.warning('Bengle firmware surface probe failed: $e');
        _bengleFeatureSurfaceSupported = false;
      }
    });
    return _bengleFeatureSurfaceSupported;
  }
}
