import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../helpers/fake_ble_transport.dart';

/// Byte-exact base-frame encoding of a cross-variable POWER exit, plus the
/// capability refusal gate and the flag-bit properties.
///
/// A power exit rides the base frame's existing TriggerVal byte (data[5], U8D1
/// watts) and the existing DC_GT over/under bit, selected by the independent
/// comparePower flag (0x80). It deliberately does NOT set doCompare (0x02): a
/// firmware/app that predates the power exit gates the pressure/flow compare
/// block on doCompare, so with it clear the frame runs to its time/volume limits
/// (a benign base frame) instead of comparing watts against pressure/flow.
///
/// Golden vectors (8-byte Endpoint.frameWrite payload data[0..7]):
///   GV-P1 pressure step, power over 4.5 W -> 02 C4 5A B8 9E 2D 04 00
///   GV-F1 flow step,     power under 2.0 W -> 03 C1 14 B4 94 14 04 00
void main() {
  // A pressure-power-over exit at step 2 and a flow-power-under exit at step 3,
  // so the encoded frame index bytes are 0x02 / 0x03 (matching the vectors).
  const goldenProfile = Profile(
    version: '2',
    title: 'power-exit golden',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    steps: [
      ProfileStepPressure(
        name: 'preinfuse',
        transition: TransitionType.fast,
        volume: 0,
        seconds: 10,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        pressure: 2.0,
      ),
      ProfileStepPressure(
        name: 'ramp',
        transition: TransitionType.fast,
        volume: 0,
        seconds: 10,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        pressure: 6.0,
      ),
      // GV-P1: pressure step 9.0 bar, 92 C, 30 s, vol 0, exit power over 4.5 W.
      ProfileStepPressure(
        name: 'hold to power',
        transition: TransitionType.fast,
        volume: 0,
        seconds: 30,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        pressure: 9.0,
        exit: StepExitCondition(
          type: ExitType.power,
          condition: ExitCondition.over,
          value: 4.5,
        ),
      ),
      // GV-F1: flow step 2.0 ml/s, 90 C, 20 s, vol 0, exit power under 2.0 W.
      ProfileStepFlow(
        name: 'flow to power',
        transition: TransitionType.fast,
        volume: 0,
        seconds: 20,
        temperature: 90,
        sensor: TemperatureSensor.coffee,
        flow: 2.0,
        exit: StepExitCondition(
          type: ExitType.power,
          condition: ExitCondition.under,
          value: 2.0,
        ),
      ),
    ],
    targetVolumeCountStart: 0,
    tankTemperature: 0,
  );

  Future<List<FakeBleWrite>> uploadFrames(Profile profile, int caps) async {
    final transport = FakeBleTransport();
    final de1 = UnifiedDe1(transport: transport);
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
    transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: caps);
    await de1.onConnect();
    await de1.setProfile(profile);
    final frames = transport.writes
        .where((w) => w.characteristicUUID == Endpoint.frameWrite.uuid)
        .toList();
    await transport.dispose();
    return frames;
  }

  // A single-step LEVER profile carrying a cross-variable POWER exit. The exit
  // encode is pump-agnostic: convertProfileFlags derives comparePower from
  // step.exit regardless of pump mode, and the base frame carries the same U8D1
  // watts TriggerVal a pressure/flow step does. The lever step additionally
  // emits its Mode=2 ext frame, which the exit does not disturb.
  Profile leverPowerProfile(ExitCondition cond, double watts) => Profile(
    version: '2',
    title: 'lever power exit',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    steps: [
      ProfileStepLever(
        name: 'lever to power',
        transition: TransitionType.fast,
        volume: 0,
        seconds: 30,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        pressure: 9.0,
        leverSpring: 0.9,
        leverGive: 1.5,
        exit: StepExitCondition(
          type: ExitType.power,
          condition: cond,
          value: watts,
        ),
      ),
    ],
    targetVolumeCountStart: 0,
    tankTemperature: 0,
  );

  group('golden vectors (power exit, Bengle caps 0xF)', () {
    late List<FakeBleWrite> frames;

    setUpAll(() async {
      // caps 0xF advertises bit3 (power exit), so the profile arms.
      frames = await uploadFrames(goldenProfile, 0xF);
    });

    test(
      'GV-P1: pressure step, power over 4.5 W -> 02 C4 5A B8 9E 2D 04 00',
      () {
        final f = frames.firstWhere((w) => w.data[0] == 0x02);
        expect(
          f.data,
          orderedEquals([0x02, 0xC4, 0x5A, 0xB8, 0x9E, 0x2D, 0x04, 0x00]),
        );
      },
    );

    test('GV-F1: flow step, power under 2.0 W -> 03 C1 14 B4 94 14 04 00', () {
      final f = frames.firstWhere((w) => w.data[0] == 0x03);
      expect(
        f.data,
        orderedEquals([0x03, 0xC1, 0x14, 0xB4, 0x94, 0x14, 0x04, 0x00]),
      );
    });

    test(
      'GV-P1 flag byte 0xC4 = ignoreLimit | comparePower | dcGT, NO doCompare',
      () {
        final flag = frames.firstWhere((w) => w.data[0] == 0x02).data[1];
        expect(flag, 0xC4);
        expect(flag & Helper.comparePower, Helper.comparePower);
        expect(flag & Helper.dcGT, Helper.dcGT, reason: 'over');
        expect(flag & Helper.doCompare, 0, reason: 'doCompare MUST be clear');
        expect(flag & Helper.dcCompF, 0, reason: 'dcCompF MUST be clear');
      },
    );

    test(
      'GV-F1 flag byte 0xC1 = ignoreLimit | ctrlF | comparePower (under)',
      () {
        final flag = frames.firstWhere((w) => w.data[0] == 0x03).data[1];
        expect(flag, 0xC1);
        expect(flag & Helper.ctrlF, Helper.ctrlF, reason: 'flow priority');
        expect(flag & Helper.comparePower, Helper.comparePower);
        expect(flag & Helper.dcGT, 0, reason: 'under -> dcGT clear');
        expect(flag & Helper.doCompare, 0, reason: 'doCompare MUST be clear');
      },
    );
  });

  group('lever step power exit (mode-agnostic encoder)', () {
    test(
      'lever + power over 4.5 W: base frame is byte-identical to the pressure '
      'GV-P1 (00 C4 5A B8 9E 2D 04 00) — the exit encode is pump-agnostic',
      () async {
        final frames = await uploadFrames(
          leverPowerProfile(ExitCondition.over, 4.5),
          0xF,
        );
        final base = frames.firstWhere((w) => w.data[0] == 0x00);
        // Same P0/temp/time/exit as the pressure GV-P1: only the ext Mode byte
        // differs, which proves the power-exit encode does not depend on pump mode.
        expect(
          base.data,
          orderedEquals([0x00, 0xC4, 0x5A, 0xB8, 0x9E, 0x2D, 0x04, 0x00]),
        );
      },
    );

    test(
      'flag byte: comparePower + dcGT set, doCompare/dcCompF/ctrlF clear',
      () async {
        final frames = await uploadFrames(
          leverPowerProfile(ExitCondition.over, 4.5),
          0xF,
        );
        final flag = frames.firstWhere((w) => w.data[0] == 0x00).data[1];
        expect(flag & Helper.comparePower, Helper.comparePower);
        expect(flag & Helper.dcGT, Helper.dcGT, reason: 'over');
        expect(flag & Helper.doCompare, 0, reason: 'doCompare MUST be clear');
        expect(flag & Helper.dcCompF, 0, reason: 'dcCompF MUST be clear');
        expect(
          flag & Helper.ctrlF,
          0,
          reason: 'a lever step is not flow priority',
        );
      },
    );

    test(
      'power under 2.0 W: flag 0xC0 (no dcGT), TriggerVal 0x14 watts',
      () async {
        final frames = await uploadFrames(
          leverPowerProfile(ExitCondition.under, 2.0),
          0xF,
        );
        final base = frames.firstWhere((w) => w.data[0] == 0x00);
        expect(
          base.data[1],
          0xC0,
          reason: 'ignoreLimit | comparePower, dcGT clear (under)',
        );
        expect(base.data[5], 0x14, reason: 'TriggerVal = U8D1(2.0 W)');
      },
    );

    test(
      'the lever step still emits its Mode=2 ext frame alongside the exit',
      () async {
        final frames = await uploadFrames(
          leverPowerProfile(ExitCondition.over, 4.5),
          0xF,
        );
        final ext = frames.firstWhere((w) => w.data[0] == 0x20); // 32 + step 0
        expect(
          ext.data[3],
          2,
          reason: 'Mode = Lever, unchanged by the power exit',
        );
      },
    );
  });

  group('convertProfileFlags: power exit does NOT set doCompare', () {
    ProfileStepPressure pressureExit(ExitType type, ExitCondition cond) =>
        ProfileStepPressure(
          name: 's',
          transition: TransitionType.fast,
          volume: 0,
          seconds: 10,
          temperature: 92,
          sensor: TemperatureSensor.coffee,
          pressure: 9.0,
          exit: StepExitCondition(type: type, condition: cond, value: 4.5),
        );

    test('power over: comparePower + dcGT, clear doCompare/dcCompF', () {
      final flag = Helper.convertProfileFlags(
        pressureExit(ExitType.power, ExitCondition.over),
      );
      expect(flag & Helper.comparePower, Helper.comparePower);
      expect(flag & Helper.dcGT, Helper.dcGT);
      expect(flag & Helper.doCompare, 0);
      expect(flag & Helper.dcCompF, 0);
    });

    test('power under: comparePower only (no dcGT), clear doCompare', () {
      final flag = Helper.convertProfileFlags(
        pressureExit(ExitType.power, ExitCondition.under),
      );
      expect(flag & Helper.comparePower, Helper.comparePower);
      expect(flag & Helper.dcGT, 0);
      expect(flag & Helper.doCompare, 0);
    });

    test('flow exit still sets doCompare + dcCompF, NOT comparePower', () {
      final flag = Helper.convertProfileFlags(
        pressureExit(ExitType.flow, ExitCondition.over),
      );
      expect(flag & Helper.doCompare, Helper.doCompare);
      expect(flag & Helper.dcCompF, Helper.dcCompF);
      expect(flag & Helper.comparePower, 0);
    });

    test('pressure exit still sets doCompare, NOT dcCompF/comparePower', () {
      final flag = Helper.convertProfileFlags(
        pressureExit(ExitType.pressure, ExitCondition.under),
      );
      expect(flag & Helper.doCompare, Helper.doCompare);
      expect(flag & Helper.dcCompF, 0);
      expect(flag & Helper.comparePower, 0);
    });
  });

  group('TriggerVal is U8D1 watts', () {
    test('10.0 W -> 0x64', () {
      expect(Helper.convert_float_to_U8D1(10.0), 0x64);
    });

    test('encoded TriggerVal byte for a 10.0 W exit is 0x64', () async {
      const p = Profile(
        version: '2',
        title: 't',
        notes: '',
        author: 'test',
        beverageType: BeverageType.espresso,
        steps: [
          ProfileStepPressure(
            name: 's',
            transition: TransitionType.fast,
            volume: 0,
            seconds: 10,
            temperature: 92,
            sensor: TemperatureSensor.coffee,
            pressure: 9.0,
            exit: StepExitCondition(
              type: ExitType.power,
              condition: ExitCondition.over,
              value: 10.0,
            ),
          ),
        ],
        targetVolumeCountStart: 0,
        tankTemperature: 0,
      );
      final frames = await uploadFrames(p, 0xF);
      final base0 = frames.firstWhere((w) => w.data[0] == 0);
      expect(base0.data[5], 0x64, reason: 'TriggerVal = U8D1(10.0 W)');
    });
  });

  group('arm-time refusal (power exit)', () {
    Profile powerExitProfile() => const Profile(
      version: '2',
      title: 'power exit only',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: [
        ProfileStepPressure(
          name: 's',
          transition: TransitionType.fast,
          volume: 0,
          seconds: 20,
          temperature: 92,
          sensor: TemperatureSensor.coffee,
          pressure: 9.0,
          exit: StepExitCondition(
            type: ExitType.power,
            condition: ExitCondition.over,
            value: 4.5,
          ),
        ),
      ],
      targetVolumeCountStart: 0,
      tankTemperature: 90,
    );

    // A plain pressure/flow cross-exit that already runs on a stock DE1 — it
    // must NEVER be gated (regression guard).
    Profile flowExitProfile() => const Profile(
      version: '2',
      title: 'flow exit only',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: [
        ProfileStepPressure(
          name: 's',
          transition: TransitionType.fast,
          volume: 0,
          seconds: 20,
          temperature: 92,
          sensor: TemperatureSensor.coffee,
          pressure: 9.0,
          exit: StepExitCondition(
            type: ExitType.flow,
            condition: ExitCondition.under,
            value: 1.5,
          ),
        ),
      ],
      targetVolumeCountStart: 0,
      tankTemperature: 90,
    );

    Future<UnifiedDe1> connect({required int model, required int caps}) async {
      final transport = FakeBleTransport();
      final de1 = UnifiedDe1(transport: transport);
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      transport.queueOnConnectResponses(v13Model: model, profileModeCaps: caps);
      await de1.onConnect();
      addTearDown(transport.dispose);
      return de1;
    }

    test('Bengle caps 0xF (bit3 set): a power exit arms (no throw)', () async {
      final de1 = await connect(model: 128, caps: 0xF);
      expect(de1.machineInfo.extra['profileModeCaps'], 0xF);
      await de1.setProfile(powerExitProfile()); // completes
    });

    test(
      'Bengle caps 0x7 (bit3 absent): a power exit is refused with 400',
      () async {
        final de1 = await connect(model: 128, caps: 0x7);
        expect(de1.machineInfo.extra['profileModeCaps'], 0x7);
        await expectLater(
          de1.setProfile(powerExitProfile()),
          throwsA(
            isA<ProfileModeUnsupportedException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('power exit condition'),
                isNot(contains('pump mode')),
              ),
            ),
          ),
        );
      },
    );

    test(
      'non-Bengle DE1: a power exit is refused (names the power exit)',
      () async {
        final de1 = await connect(model: 1, caps: 0);
        expect(de1.isBengle, isFalse);
        await expectLater(
          de1.setProfile(powerExitProfile()),
          throwsA(
            isA<ProfileModeUnsupportedException>().having(
              (e) => e.message,
              'message',
              contains('power exit condition'),
            ),
          ),
        );
      },
    );

    test('regression: a flow cross-exit is NOT gated on a stock DE1', () async {
      final de1 = await connect(model: 1, caps: 0);
      expect(de1.isBengle, isFalse);
      // A pressure/flow cross-exit runs on stock firmware; it must arm without
      // any capability refusal.
      await de1.setProfile(flowExitProfile()); // completes
    });

    // A LEVER step whose pump mode IS supported at caps 0x7 (Lever = bit1) but
    // which ALSO carries a power exit (bit3, absent at 0x7). The power exit is
    // an orthogonal gate: the refusal must name the power EXIT condition, never
    // the (supported) lever pump mode.
    test(
      'Bengle caps 0x7: a lever-step power exit is refused, naming the exit',
      () async {
        final de1 = await connect(model: 128, caps: 0x7);
        expect(de1.machineInfo.extra['profileModeCaps'], 0x7);
        await expectLater(
          de1.setProfile(leverPowerProfile(ExitCondition.over, 4.5)),
          throwsA(
            isA<ProfileModeUnsupportedException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('power exit condition'),
                isNot(contains('pump mode')),
              ),
            ),
          ),
        );
      },
    );

    test('Bengle caps 0xF: a lever-step power exit arms (no throw)', () async {
      final de1 = await connect(model: 128, caps: 0xF);
      expect(de1.machineInfo.extra['profileModeCaps'], 0xF);
      await de1.setProfile(leverPowerProfile(ExitCondition.over, 4.5)); // ok
    });
  });

  group('caps mask widening to 0xF', () {
    Future<UnifiedDe1> connectCaps(int caps) async {
      final transport = FakeBleTransport();
      final de1 = UnifiedDe1(transport: transport);
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: caps);
      await de1.onConnect();
      addTearDown(transport.dispose);
      return de1;
    }

    test('0x9 (Power + power exit) survives the widened ~0xF mask', () async {
      final de1 = await connectCaps(0x9);
      expect(de1.machineInfo.extra['profileModeCaps'], 0x9);
    });

    test('0xF survives (all bits) — not zeroed by the mask', () async {
      final de1 = await connectCaps(0xF);
      expect(de1.machineInfo.extra['profileModeCaps'], 0xF);
    });

    test('a stray bit above 0xF still fail-closes to 0', () async {
      final de1 = await connectCaps(0x10);
      expect(de1.machineInfo.extra['profileModeCaps'], 0);
    });
  });
}
