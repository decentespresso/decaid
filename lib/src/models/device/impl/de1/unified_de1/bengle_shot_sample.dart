import 'dart:typed_data';

const bengleShotSampleLength = 28;

final class BengleShotSample {
  const BengleShotSample({
    required this.sampleTime,
    required this.groupPressure,
    required this.setGroupPressure,
    required this.groupFlow,
    required this.setGroupFlow,
    required this.gFlow,
    required this.mixTemperature,
    required this.groupTemperature,
    required this.setMixTemperature,
    required this.setGroupTemperature,
    required this.weight,
    required this.frameNumber,
    required this.steamTemperature,
    required this.milkTemperature,
    required this.flags,
  });

  final int sampleTime;
  final double groupPressure;
  final double setGroupPressure;
  final double groupFlow;
  final double setGroupFlow;
  final double gFlow;
  final double mixTemperature;
  final double groupTemperature;
  final double setMixTemperature;
  final double setGroupTemperature;

  /// Integrated-scale weight in grams, already NET of the firmware tare.
  ///
  /// Wire format S16P4 at offset 20: SIGNED big-endian 16-bit, 4 fractional
  /// bits, so `int16 / 16`. Range -2048 .. +2047.9375 g, step 0.0625 g.
  ///
  /// **This value is legitimately negative.** Net weight is `CurrW - LastTARE`,
  /// so unloading the platform after a tare, lifting the cup, or a drip-back
  /// all produce a real reading below zero. Do not clamp it, and do not take
  /// `abs()`: a consumer that hides the sign is reporting a lie about the cup.
  ///
  /// The field was unsigned U16P5 (`uint16 / 32`) until Aug 2026, which
  /// clamped every negative to 0 in the firmware before it reached the wire.
  /// A decoder still dividing by 32 reports HALF the true weight and raises
  /// no error, because the frame length is unchanged at 28 bytes.
  final double weight;
  final int frameNumber;
  final double steamTemperature;
  final double milkTemperature;
  final int flags;
}

BengleShotSample? decodeBengleShotSample(ByteData data) {
  if (data.lengthInBytes < bengleShotSampleLength) return null;
  return BengleShotSample(
    sampleTime: data.getUint16(0, Endian.big),
    groupPressure: data.getUint16(2, Endian.big) / 100,
    setGroupPressure: data.getUint16(4, Endian.big) / 100,
    groupFlow: data.getUint16(6, Endian.big) / 100,
    setGroupFlow: data.getUint16(8, Endian.big) / 100,
    gFlow: data.getUint16(10, Endian.big) / 100,
    mixTemperature: data.getUint16(12, Endian.big) / 100,
    groupTemperature: data.getUint16(14, Endian.big) / 100,
    setMixTemperature: data.getUint16(16, Endian.big) / 100,
    setGroupTemperature: data.getUint16(18, Endian.big) / 100,
    weight: data.getInt16(20, Endian.big) / 16,
    frameNumber: data.getUint8(22),
    steamTemperature: data.getUint16(23, Endian.big) / 100,
    milkTemperature: data.getUint16(25, Endian.big) / 100,
    flags: data.getUint8(27),
  );
}
