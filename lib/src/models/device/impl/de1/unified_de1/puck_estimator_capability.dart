part of 'unified_de1.dart';

/// Decoded Bengle `0xA014` fused puck-estimator frames.
///
/// The transport subject is seeded with a ZERO-LENGTH frame, which
/// [parseBengleEstSample] rejects, so nothing is emitted until real `[T]` data
/// arrives. That is what lets a consumer treat "no event yet" as "this machine
/// has no estimator" rather than reading a run of zeros as real observations.
///
/// Over serial/CDC the stream is unconditional. Over BLE it depends on the
/// machine: [UnifiedDe1Transport.subscribeEstimator] subscribes only when the
/// peripheral actually registers `0xA014`, so firmware predating that
/// registration leaves this stream silent.
mixin PuckEstimatorCapability on UnifiedDe1 {
  Stream<BengleEstSample> get puckEstimator => _transport.estimator
      .map(parseBengleEstSample)
      .whereType<BengleEstSample>();
}
