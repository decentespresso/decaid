part of 'unified_de1.dart';

enum BengleLedEndpoint implements LogicalEndpoint {
  frontStripSleeping,
  frontStripAwake,
  backStripSleeping,
  backStripAwake,
  frontSwitchSleeping,
  frontSwitchAwake,
  commitConfig,
  resetConfig;

  @override
  String? get uuid => null;

  @override
  String? get representation => null;

  @override
  String get name => (this as Enum).name;
}

mixin LedStripCapability on UnifiedDe1 {
  BehaviorSubject<LedStripState> _ledStripState =
      BehaviorSubject<LedStripState>.seeded(const LedStripState());

  int _stubWarningsEmitted = 0;

  Stream<LedStripState> get ledStripState => _ledStripState.stream;

  Future<LedStripState> getLedStripState() => _ledStripState.first;

  Future<void> setLedStrip(LedStripState state) async {
    _logStubOnce('setLedStrip($state) ignored. Awaiting FW.');
    _ledStripState.add(state);
  }

  Future<void> commitLedStrip() async {
    _logStubOnce('commitLedStrip() ignored. Awaiting FW.');
  }

  Future<void> resetLedStrip() async {
    _logStubOnce('resetLedStrip() ignored. Awaiting FW.');
  }

  void _logStubOnce(String msg) {
    if (_stubWarningsEmitted < 1) {
      this.log.info('LedStripCapability: endpoints unwired; $msg');
      _stubWarningsEmitted++;
    }
  }

  Future<void> initLedStrip() async {
    if (_ledStripState.isClosed) {
      _ledStripState = BehaviorSubject<LedStripState>.seeded(
        const LedStripState(),
      );
    }
    _stubWarningsEmitted = 0;
    _logStubOnce('no write surface registered. Awaiting FW.');
  }

  Future<void> disposeLedStrip() async {
    if (!_ledStripState.isClosed) {
      await _ledStripState.close();
    }
  }
}
