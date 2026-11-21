import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/services/warmup_logger.dart';
import 'package:rxdart/rxdart.dart';

import '../helpers/test_de1.dart';

final _t0 = DateTime(2026, 11, 20, 7);

MachineSnapshot _snapshot(
  int seconds, {
  MachineState state = MachineState.heating,
  double group = 24.1,
  double targetGroup = 93,
  int steam = 31,
}) => MachineSnapshot(
  timestamp: _t0.add(Duration(seconds: seconds)),
  state: MachineStateSnapshot(state: state, substate: MachineSubstate.idle),
  flow: 0,
  pressure: 0,
  targetFlow: 0,
  targetPressure: 0,
  mixTemperature: group,
  groupTemperature: group,
  targetMixTemperature: targetGroup,
  targetGroupTemperature: targetGroup,
  profileFrame: 0,
  steamTemperature: steam,
);

De1ShotSettings _settings({int targetSteamTemp = 160}) => De1ShotSettings(
  steamSetting: 0,
  targetSteamTemp: targetSteamTemp,
  targetSteamDuration: 60,
  targetHotWaterTemp: 80,
  targetHotWaterVolume: 100,
  targetHotWaterDuration: 30,
  targetShotVolume: 36,
  groupTemp: 93,
);

void main() {
  late BehaviorSubject<De1Interface?> machines;
  late TestDe1 de1;
  late WarmupLogger logger;
  late List<String> lines;
  late StreamSubscription<LogRecord> logSub;

  setUp(() async {
    machines = BehaviorSubject.seeded(null);
    de1 = TestDe1();
    lines = [];
    logSub = Logger.root.onRecord
        .where((r) => r.loggerName == 'Warmup' && r.level == Level.INFO)
        .listen((r) => lines.add(r.message));
    logger = WarmupLogger(machines: machines.stream);
  });

  tearDown(() async {
    await logger.dispose();
    await logSub.cancel();
    await de1.dispose();
    await machines.close();
  });

  Future<void> emit(MachineSnapshot snapshot) async {
    de1.emitSnapshot(snapshot);
    await pumpEventQueue();
  }

  Future<void> connect({int targetSteamTemp = 160}) async {
    de1.emitShotSettings(_settings(targetSteamTemp: targetSteamTemp));
    de1.emitSnapshot(_snapshot(0, state: MachineState.sleeping));
    machines.add(de1);
    await pumpEventQueue();
  }

  test('wake from sleep logs each milestone once', () async {
    await connect();

    await emit(_snapshot(10));
    await emit(_snapshot(68, steam: 136));
    await emit(_snapshot(70, steam: 140));
    await emit(_snapshot(105, steam: 160));
    await emit(_snapshot(152, group: 93.0, steam: 161));
    await emit(_snapshot(160, group: 93.4, steam: 162));

    expect(lines, [
      'Warmup start: from=sleep, group=24.1C, steam=31C',
      'Warmup steam ready: 58s (steam 31C -> 135C)',
      'Warmup steam final: 95s (steam 31C -> 160C)',
      'Warmup espresso ready: 142s (group 24.1C -> 93.0C)',
    ]);
  });

  test('connecting to a cold awake machine starts a session', () async {
    de1.emitShotSettings(_settings());
    de1.emitSnapshot(_snapshot(0, group: 40));
    machines.add(de1);
    await pumpEventQueue();

    await emit(_snapshot(90, group: 93));

    expect(lines, [
      'Warmup start: from=connect, group=40.0C, steam=31C',
      'Warmup espresso ready: 90s (group 40.0C -> 93.0C)',
    ]);
  });

  test('connecting to a machine already at temperature logs nothing', () async {
    de1.emitShotSettings(_settings());
    de1.emitSnapshot(_snapshot(0, state: MachineState.idle, group: 93));
    machines.add(de1);
    await pumpEventQueue();

    await emit(_snapshot(30, state: MachineState.idle, group: 93));

    expect(lines, isEmpty);
  });

  test('steam lines are skipped when steam is off', () async {
    await connect(targetSteamTemp: 0);

    await emit(_snapshot(10));
    await emit(_snapshot(150, group: 93, steam: 140));

    expect(lines, [
      'Warmup start: from=sleep, group=24.1C, steam=31C',
      'Warmup espresso ready: 140s (group 24.1C -> 93.0C)',
    ]);
  });

  test('going back to sleep drops the session', () async {
    await connect();

    await emit(_snapshot(10));
    await emit(_snapshot(40, state: MachineState.sleeping));
    await emit(_snapshot(400, state: MachineState.sleeping, group: 93));

    expect(lines, ['Warmup start: from=sleep, group=24.1C, steam=31C']);
  });

  test('a session that never reaches temperature is dropped', () async {
    await connect(targetSteamTemp: 0);

    await emit(_snapshot(10));
    await emit(_snapshot(10 + 31 * 60, group: 93));

    expect(lines, ['Warmup start: from=sleep, group=24.1C, steam=31C']);
  });
}
