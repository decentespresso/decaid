import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';

const int steamReadyCelsius = 135;

class WarmupLogger {
  WarmupLogger({required Stream<De1Interface?> machines}) {
    _machineSub = machines.listen(_attach);
  }

  static const _maxSession = Duration(minutes: 30);

  final Logger _log = Logger('Warmup');
  late final StreamSubscription<De1Interface?> _machineSub;
  StreamSubscription<MachineSnapshot>? _snapshotSub;
  StreamSubscription<De1ShotSettings>? _settingsSub;

  int? _targetSteam;
  MachineState? _lastState;
  bool _justConnected = false;
  _Session? _session;

  void _attach(De1Interface? machine) {
    _snapshotSub?.cancel();
    _settingsSub?.cancel();
    _snapshotSub = null;
    _settingsSub = null;
    _targetSteam = null;
    _lastState = null;
    _session = null;
    if (machine == null) return;
    _justConnected = true;
    _settingsSub = machine.shotSettings.listen(
      (s) => _targetSteam = s.targetSteamTemp,
      onError: (_) {},
    );
    _snapshotSub = machine.currentSnapshot.listen(_onSnapshot, onError: (_) {});
  }

  void _onSnapshot(MachineSnapshot s) {
    final state = s.state.state;
    final wokeUp = _lastState == MachineState.sleeping;
    final connected = _justConnected;
    _justConnected = false;
    _lastState = state;

    if (state == MachineState.sleeping) {
      _session = null;
      return;
    }
    if (_session == null &&
        (wokeUp || connected) &&
        s.groupTemperature < s.targetGroupTemperature) {
      _session = _Session(s);
      _log.info(
        'Warmup start: from=${wokeUp ? 'sleep' : 'connect'}, '
        'group=${_c(s.groupTemperature)}, steam=${s.steamTemperature}C',
      );
    }
    final session = _session;
    if (session == null) return;

    final elapsed = s.timestamp.difference(session.start.timestamp);
    if (elapsed > _maxSession) {
      _session = null;
      return;
    }
    final seconds = elapsed.inSeconds;
    final steamTarget = _targetSteam;
    final steamOn = steamTarget != null && steamTarget >= steamReadyCelsius;

    if (steamOn &&
        !session.steamReady &&
        s.steamTemperature >= steamReadyCelsius) {
      session.steamReady = true;
      _log.info(
        'Warmup steam ready: ${seconds}s '
        '(steam ${session.start.steamTemperature}C -> ${steamReadyCelsius}C)',
      );
    }
    if (steamOn && !session.steamFinal && s.steamTemperature >= steamTarget) {
      session.steamFinal = true;
      _log.info(
        'Warmup steam final: ${seconds}s '
        '(steam ${session.start.steamTemperature}C -> ${steamTarget}C)',
      );
    }
    if (!session.espresso && s.groupTemperature >= s.targetGroupTemperature) {
      session.espresso = true;
      _log.info(
        'Warmup espresso ready: ${seconds}s '
        '(group ${_c(session.start.groupTemperature)} -> '
        '${_c(s.targetGroupTemperature)})',
      );
    }
    if (session.espresso && (!steamOn || session.steamFinal)) _session = null;
  }

  static String _c(double celsius) => '${celsius.toStringAsFixed(1)}C';

  Future<void> dispose() async {
    await _machineSub.cancel();
    await _snapshotSub?.cancel();
    await _settingsSub?.cancel();
  }
}

class _Session {
  _Session(this.start);

  final MachineSnapshot start;
  bool espresso = false;
  bool steamReady = false;
  bool steamFinal = false;
}
