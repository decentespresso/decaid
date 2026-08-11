import 'dart:async';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/models/device/impl/replay/shot_replayer.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/simulated_shot_library.dart';
import 'package:rxdart/subjects.dart';

/// A simulated DE1 that replays a real recorded shot instead of synthesizing
/// telemetry. It picks a bundled recording made with the currently selected
/// profile when one exists (see [SimulatedShotLibrary]), otherwise a generic
/// fallback, and streams that recording's samples on the shot timeline.
///
/// It extends [MockDe1] purely to inherit the large [De1Interface] surface
/// (shot settings, water levels, firmware, calibration, ...) as no-op stubs;
/// the puck-physics simulation in [MockDe1] is never used — this class runs its
/// own connection, snapshot stream and timer. Keeping replay in its own device
/// leaves [MockDe1] a single-responsibility puck simulator.
class MockReplayDe1 extends MockDe1 {
  MockReplayDe1({required SimulatedShotLibrary library, Random? random})
    : _library = library,
      _random = random ?? Random(),
      super(deviceId: "MockReplayDe1");

  final SimulatedShotLibrary _library;
  final Random _random;
  final _log = Logger("MockReplayDe1");

  final BehaviorSubject<ConnectionState> _connection = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final StreamController<MachineSnapshot> _snapshots =
      StreamController.broadcast();

  Timer? _timer;
  int _idleTicks = 0;
  MachineState _state = MachineState.idle;
  Profile? _profile;

  ShotReplayer? _replayer;
  DateTime _replayStartedAt = DateTime.now();
  double? _replayWeightGrams;

  /// Recorded scale weight at the current replay position, for [MockReplayScale]
  /// to report directly. Null when no shot is loaded; held after the recording
  /// ends so the reading rests at the final poured weight.
  double? get replayWeightGrams => _replayWeightGrams;

  @override
  String get deviceId => "MockReplayDe1";

  @override
  String get name => "Replay DE1";

  @override
  Stream<ConnectionState> get connectionState => _connection.stream;

  @override
  Stream<MachineSnapshot> get currentSnapshot => _snapshots.stream;

  @override
  Future<void> onConnect() async {
    _connection.add(ConnectionState.connected);
    _state = MachineState.idle;
    _timer ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _tick(),
    );
  }

  @override
  disconnect() async {
    _timer?.cancel();
    _timer = null;
    _replayer = null;
    _connection.add(ConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _snapshots.close();
    await _connection.close();
  }

  @override
  Future<void> setProfile(Profile profile) async {
    _profile = profile;
  }

  @override
  Future<void> requestState(MachineState newState) async {
    _state = newState;
    if (newState == MachineState.espresso) {
      _startReplay();
    } else {
      _replayer = null;
      _replayWeightGrams = null;
    }
  }

  void _startReplay() {
    _replayWeightGrams = null;
    final shot = _library.pickForProfile(_profile?.title, _random);
    if (shot == null || shot.measurements.isEmpty) {
      _replayer = null;
      _log.warning("no recorded shot available to replay");
      return;
    }
    _replayer = ShotReplayer(shot.measurements);
    _replayStartedAt = DateTime.now();
    final matched = _library.forProfileTitle(_profile?.title) != null;
    _log.info(
      "replaying ${shot.id} for profile '${_profile?.title}' "
      "(${matched ? 'profile match' : 'fallback'}, "
      "${shot.measurements.length} samples)",
    );
  }

  // Recordings begin at the pour, but the ShotSequencer only starts a shot
  // when it sees an espresso/preparingForShot frame first. Synthesize that
  // brief preparing phase so replay drives the normal shot lifecycle (tare,
  // stop-at-weight, step exits) exactly like a real pull.
  static const double _prepSeconds = 0.3;

  void _tick() {
    final replayer = _replayer;
    if (replayer != null && _state == MachineState.espresso) {
      final now = DateTime.now();
      final elapsed = now.difference(_replayStartedAt).inMilliseconds / 1000.0;
      _replayWeightGrams =
          replayer.scaleAt(elapsed)?.weight ?? _replayWeightGrams;
      var frame = replayer.frameAt(elapsed, timestamp: now);
      if (elapsed < _prepSeconds) {
        frame = frame.copyWith(
          state: const MachineStateSnapshot(
            state: MachineState.espresso,
            substate: MachineSubstate.preparingForShot,
          ),
        );
      }
      _snapshots.add(frame);
      if (replayer.isFinished(elapsed)) {
        _state = MachineState.idle;
        _replayer = null;
      }
      return;
    }
    // Idle heartbeat every ~500ms so listeners see a live, ready machine.
    if (_idleTicks++ % 5 == 0) {
      _snapshots.add(_idleSnapshot());
    }
  }

  MachineSnapshot _idleSnapshot() {
    final temp = _profile?.steps.isNotEmpty == true
        ? _profile!.steps.first.temperature
        : 90.0;
    return MachineSnapshot(
      timestamp: DateTime.now(),
      state: MachineStateSnapshot(
        state: _state,
        substate: MachineSubstate.idle,
      ),
      flow: 0,
      pressure: 0,
      targetFlow: 0,
      targetPressure: 0,
      mixTemperature: temp,
      groupTemperature: temp,
      targetMixTemperature: temp,
      targetGroupTemperature: temp,
      profileFrame: 0,
      steamTemperature: 0,
    );
  }
}
