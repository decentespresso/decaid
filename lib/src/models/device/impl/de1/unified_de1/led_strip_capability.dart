part of 'unified_de1.dart';

/// Wire endpoints for Bengle's LED zones.
///
/// Six zone-mode colour writes (frontStrip/backStrip/frontSwitch ×
/// sleeping/awake) plus two control endpoints for NVM commit/reset.
///
/// All [uuid] and [representation] return `null` for now — the firmware
/// slots have not yet been published. The [LedStripCapability] mixin
/// treats null wires as "capability not yet wired" and silently no-ops
/// (with an info log per session). Once FW publishes the wire spec,
/// fill these in and the rest lights up unchanged.
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

/// Stateful capability for Bengle's 3-zone LED strip (front strip,
/// back strip, front switch) with sleeping/awake mode colours.
///
/// Owns the current [LedStripState] and exposes getter/setter plus
/// [commitLedStrip] (persist to FW NVM) and [resetLedStrip] (reload
/// from FW NVM). Lifecycle is managed by the concrete `Bengle` device
/// — call [initLedStrip] from `onConnect`, [disposeLedStrip] from
/// `onDisconnect`.
///
/// The capability is a no-op until firmware publishes the wire identifiers
/// (see [BengleLedEndpoint]); when that happens, [setLedStrip] writes
/// all six zone-mode endpoints, [commitLedStrip] writes the commit
/// endpoint, and [resetLedStrip] writes the reset endpoint then
/// re-reads the cache.
mixin LedStripCapability on UnifiedDe1 {
  BehaviorSubject<LedStripState> _ledStripState =
      BehaviorSubject<LedStripState>.seeded(const LedStripState());

  /// Count of info-log messages emitted this session to avoid log spam.
  int _stubWarningsEmitted = 0;

  /// Current LED strip state (cached in SB, not necessarily committed to FW).
  Stream<LedStripState> get ledStripState => _ledStripState.stream;

  /// One-shot read of the current cached LED strip state.
  Future<LedStripState> getLedStripState() => _ledStripState.first;

  /// Write a full configuration to cache and to FW live registers.
  ///
  /// Updates all six zone-mode colours. The FW auto-selects between
  /// sleeping and awake based on its internal machine state. Does NOT
  /// persist to NVM — call [commitLedStrip] separately.
  Future<void> setLedStrip(LedStripState state) async {
    _logStubOnce('setLedStrip($state) ignored. Awaiting FW.');
    _ledStripState.add(state);
  }

  /// Persist the current cache to FW NVM. The machine retains the last
  /// committed state across power cycles.
  Future<void> commitLedStrip() async {
    _logStubOnce('commitLedStrip() ignored. Awaiting FW.');
  }

  /// Reload cache from FW NVM. Drops any uncommitted changes.
  Future<void> resetLedStrip() async {
    _logStubOnce('resetLedStrip() ignored. Awaiting FW.');
  }

  /// Emit an info-level log once per session for stub-related messages.
  void _logStubOnce(String msg) {
    if (_stubWarningsEmitted < 1) {
      this.log.info('LedStripCapability: endpoints unwired; $msg');
      _stubWarningsEmitted++;
    }
  }

  /// Re-init-safe: if a previous [disposeLedStrip] closed the subject,
  /// a fresh one is created here.
  Future<void> initLedStrip() async {
    if (_ledStripState.isClosed) {
      _ledStripState = BehaviorSubject<LedStripState>.seeded(
        const LedStripState(),
      );
    }
    _stubWarningsEmitted = 0;
    _logStubOnce('no write surface registered. Awaiting FW.');
  }

  /// Cancel any subscriptions and close the subject.
  Future<void> disposeLedStrip() async {
    if (!_ledStripState.isClosed) {
      await _ledStripState.close();
    }
  }
}
