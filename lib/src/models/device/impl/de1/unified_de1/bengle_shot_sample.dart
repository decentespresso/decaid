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
    weight: data.getUint16(20, Endian.big) / 32,
    frameNumber: data.getUint8(22),
    steamTemperature: data.getUint16(23, Endian.big) / 100,
    milkTemperature: data.getUint16(25, Endian.big) / 100,
    flags: data.getUint8(27),
  );
}
