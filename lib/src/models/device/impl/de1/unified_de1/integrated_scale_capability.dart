part of 'unified_de1.dart';

enum BengleScaleMmr implements MmrAddress {
  endOfShotWeight(
    0x00803864,
    4,
    MmrValueKind.scaledFloat,
    'EndOfShotWeight',
    min: 0,
    max: 1000000,
    readScale: 0.01,
    writeScale: 100,
  ),
  scaleTare(0x0080388C, 4, MmrValueKind.int32, 'ScaleTare');

  const BengleScaleMmr(
    this.address,
    this.length,
    this.kind,
    this.description, {
    this.readScale = 1,
    this.writeScale = 1,
    this.min,
    this.max,
  });

  @override
  final int address;
  @override
  final int length;
  @override
  final MmrValueKind kind;
  final String description;
  @override
  final double readScale;
  @override
  final double writeScale;
  @override
  final int? min;
  @override
  final int? max;

  @override
  String get name => (this as Enum).name;
}

mixin IntegratedScaleCapability on UnifiedDe1 {
  ReplaySubject<ScaleSnapshot> _bengleWeight = ReplaySubject(maxSize: 1);
  StreamSubscription<ByteData>? _bengleWeightSub;
  BehaviorSubject<double> _sawTarget = BehaviorSubject.seeded(0);

  Stream<ScaleSnapshot> get weightSnapshot => _bengleWeight.stream;

  Stream<double> get stopAtWeightTarget => _sawTarget.stream;

  Future<void> initIntegratedScale() async {
    if (_bengleWeight.isClosed) {
      _bengleWeight = ReplaySubject(maxSize: 1);
    }
    if (_sawTarget.isClosed) {
      _sawTarget = BehaviorSubject.seeded(0);
    }
    await _bengleWeightSub?.cancel();
    _bengleWeightSub = notificationsFor(
      Endpoint.bengleShotSample,
    ).listen(_handleBengleShotSample);
  }

  Future<void> disposeIntegratedScale() async {
    await _bengleWeightSub?.cancel();
    _bengleWeightSub = null;
    if (!_bengleWeight.isClosed) await _bengleWeight.close();
    if (!_sawTarget.isClosed) await _sawTarget.close();
  }

  Future<void> tareIntegratedScale() async {
    try {
      await writeMmrInt(BengleScaleMmr.scaleTare, 1);
    } on DeviceNotConnectedException {
      return;
    }
  }

  Future<void> setStopAtWeightTarget(double grams) async {
    final target = grams.clamp(0, 10000).toDouble();
    if (!_sawTarget.isClosed) _sawTarget.add(target);
    await writeMmrScaled(BengleScaleMmr.endOfShotWeight, target);
  }

  Future<double> getStopAtWeightTarget() async {
    final target = await readMmrScaled(BengleScaleMmr.endOfShotWeight);
    if (!_sawTarget.isClosed) _sawTarget.add(target);
    return target;
  }

  void _handleBengleShotSample(ByteData frame) {
    final sample = decodeBengleShotSample(frame);
    if (sample == null || _bengleWeight.isClosed) return;
    _bengleWeight.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: sample.weight,
        batteryLevel: 100,
        flow: sample.gFlow,
      ),
    );
  }
}
