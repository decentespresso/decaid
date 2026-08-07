part of 'unified_de1.dart';

enum BengleScaleEndpoint implements LogicalEndpoint {
  weight,

  control;

  @override
  String? get uuid => null;

  @override
  String? get representation => null;

  @override
  String get name => (this as Enum).name;
}

enum BengleScaleMmr implements MmrAddress {
  stopAtWeightTarget(
    0x00000000,
    4,
    MmrValueKind.scaledFloat,
    'StopAtWeightTarget',
    min: 0,
    max: 5000,
    readScale: 0.1,
    writeScale: 10.0,
  );

  const BengleScaleMmr(
    this.address,
    this.length,
    this.kind,
    this.description, {
    this.readScale = 1.0,
    this.writeScale = 1.0,
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
  BehaviorSubject<ScaleSnapshot> _bengleWeight =
      BehaviorSubject<ScaleSnapshot>();
  StreamSubscription<ByteData>? _bengleWeightSub;

  BehaviorSubject<double> _sawTarget = BehaviorSubject<double>.seeded(0.0);

  int _sawStubWarningsEmitted = 0;

  Stream<ScaleSnapshot> get weightSnapshot => _bengleWeight.stream;

  Stream<double> get stopAtWeightTarget => _sawTarget.stream;

  Future<void> initIntegratedScale() async {
    if (_bengleWeight.isClosed) {
      _bengleWeight = BehaviorSubject<ScaleSnapshot>();
    }
    if (_sawTarget.isClosed) {
      _sawTarget = BehaviorSubject<double>.seeded(0.0);
    }
    final endpoint = BengleScaleEndpoint.weight;
    if (endpoint.uuid == null && endpoint.representation == null) {
      this.log.info(
        'IntegratedScaleCapability: weight endpoint unwired; '
        'no notify subscription. Awaiting FW.',
      );
      return;
    }
  }

  Future<void> disposeIntegratedScale() async {
    await _bengleWeightSub?.cancel();
    _bengleWeightSub = null;
    if (!_bengleWeight.isClosed) {
      await _bengleWeight.close();
    }
    if (!_sawTarget.isClosed) {
      await _sawTarget.close();
    }
  }

  Future<void> tareIntegratedScale() async {
    final ctl = BengleScaleEndpoint.control;
    if (ctl.uuid == null && ctl.representation == null) {
      this.log.info(
        'IntegratedScaleCapability: tare ignored — control '
        'endpoint unwired. Awaiting FW.',
      );
      return;
    }
  }

  Future<void> setStopAtWeightTarget(double grams) async {
    final clamped = grams.clamp(0.0, 500.0).toDouble();
    if (!_sawTarget.isClosed) {
      _sawTarget.add(clamped);
    }
    final addr = BengleScaleMmr.stopAtWeightTarget;
    if (addr.address == 0x00000000) {
      _logSawStubOnce('setStopAtWeightTarget($clamped) ignored. Awaiting FW.');
      return;
    }
    await writeMmrScaled(addr, clamped);
  }

  Future<double> getStopAtWeightTarget() async {
    final addr = BengleScaleMmr.stopAtWeightTarget;
    if (addr.address == 0x00000000) {
      return _sawTarget.value;
    }
    final value = await readMmrScaled(addr);
    if (!_sawTarget.isClosed) {
      _sawTarget.add(value);
    }
    return value;
  }

  void _logSawStubOnce(String msg) {
    if (_sawStubWarningsEmitted < 1) {
      this.log.info('IntegratedScaleCapability: SAW endpoint unwired; $msg');
      _sawStubWarningsEmitted++;
    }
  }

  // ignore: unused_element
  void _handleWeightFrame(ByteData frame) {
    this.log.warning(
      'IntegratedScaleCapability: weight frame received but '
      'parser not yet implemented (FW spec TBD)',
    );
  }

  // ignore: unused_element
  List<int> _encodeTareCommand() => const [];
}
