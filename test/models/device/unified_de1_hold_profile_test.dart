import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../helpers/fake_ble_transport.dart';

/// Byte-exact ext-frame encoding for the additive HOLD transition, plus the
/// capability refusal gate and the HOLD-as-first-step rejection.
///
/// A HOLD step carries NO authored target — the firmware latches the value
/// achieved at the exit of the previous step. reaprime therefore:
///   * pins the base-frame SetVal to 0 (benign vent/pause on firmware without
///     the HOLD modes);
///   * emits a dedicated ext frame with the HOLD Mode byte
///     (data[3] = 3 HOLD-pressure / 4 HOLD-flow / 5 HOLD-power);
///   * never sets the base interpolate bit (HOLD rides its own Mode marker).
///
/// Golden bytes (U8D1 = value×10, base temp 92C=0xB8, 30s F8_1_7=0x9E,
/// vol0 U10P0=0x0400):
///   HOLD-pressure ext: [.., 0x3C, 0x06, 0x03, 0, 0, 0, 0] (flow cap 6.0/0.6)
///   HOLD-flow ext:     [.., 0x5A, 0x09, 0x04, 0, 0, 0, 0] (pres cap 9.0/0.9)
///   HOLD-power ext:    [.., 0x00, 0x00, 0x05, 0x5A, 0, 0, 0] (cap 9.0)
void main() {
  // Step 0: a benign flow fill (no HOLD — HOLD can't be first). Steps 1..3 are
  // the three HOLD variants carrying the golden limiters.
  const profile = Profile(
    version: '2',
    title: 'hold encoder profile',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    steps: [
      ProfileStepFlow(
        name: 'fill',
        transition: TransitionType.fast,
        volume: 0,
        seconds: 10,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        flow: 8.0,
      ),
      // HOLD-pressure: authored pressure ignored (stored 0), flow cap 6.0.
      ProfileStepPressure(
        name: 'hold pressure',
        transition: TransitionType.hold,
        volume: 0,
        seconds: 30,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        pressure: 0,
        limiter: StepLimiter(value: 6.0, range: 0.6),
      ),
      // HOLD-flow: authored flow ignored (stored 0), pressure cap 9.0.
      ProfileStepFlow(
        name: 'hold flow',
        transition: TransitionType.hold,
        volume: 0,
        seconds: 30,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        flow: 0,
        limiter: StepLimiter(value: 9.0, range: 0.9),
      ),
      // HOLD-power: authored watts ignored (stored 0), mandatory cap 9.0.
      ProfileStepPower(
        name: 'hold power',
        transition: TransitionType.hold,
        volume: 0,
        seconds: 30,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        power: 0,
        limiter: StepLimiter(value: 9.0, range: 0.6),
      ),
    ],
    targetVolumeCountStart: 0,
    tankTemperature: 0,
  );

  Future<List<FakeBleWrite>> uploadFrames(int caps) async {
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

  group('caps read widened to 0x7 (bit2 = HOLD)', () {
    test('a HOLD firmware reporting 0x7 is preserved, not zeroed', () async {
      final transport = FakeBleTransport();
      final de1 = UnifiedDe1(transport: transport);
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: 0x7);
      await de1.onConnect();
      // The old 0x3 garbage-guard would have zeroed a legitimate 0x7; the
      // widened 0x7 mask keeps it (Power|Lever|HOLD all advertised).
      expect(de1.machineInfo.extra['profileModeCaps'], 0x7);
      await transport.dispose();
    });

    test('a word with a bit above 0x7 still fails-closed to 0', () async {
      final transport = FakeBleTransport();
      final de1 = UnifiedDe1(transport: transport);
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: 0x1F);
      await de1.onConnect();
      expect(de1.machineInfo.extra['profileModeCaps'], 0);
      await transport.dispose();
    });
  });

  group('Bengle HOLD ext-frame encoding (caps 0x7)', () {
    late List<FakeBleWrite> frames;

    setUpAll(() async {
      frames = await uploadFrames(0x7);
    });

    test('sequence = 4 base + 3 ext + tail (fill emits no ext)', () {
      // Base frames 0..3, ext frames only for the three HOLD steps (33/34/35),
      // then the tail. The fill (step 0, no limiter, legacy) emits no ext frame.
      expect(frames, hasLength(8));
      expect(frames[0].data[0], 0, reason: 'base frame 0 (fill)');
      expect(frames[1].data[0], 1, reason: 'base frame 1 (hold-pressure)');
      expect(frames[2].data[0], 2, reason: 'base frame 2 (hold-flow)');
      expect(frames[3].data[0], 3, reason: 'base frame 3 (hold-power)');
      expect(frames[4].data[0], 33, reason: 'ext frame step 1');
      expect(frames[5].data[0], 34, reason: 'ext frame step 2');
      expect(frames[6].data[0], 35, reason: 'ext frame step 3');
      expect(frames[7].data[0], 4, reason: 'tail = steps.length');
    });

    test('HOLD-pressure base: flag 0x40, SetVal 0, no interpolate', () {
      final d = frames[1].data;
      // ignoreLimit(0x40) only: pressure-priority, no CtrlF, no interpolate.
      expect(d[1], 0x40, reason: 'flag: ignoreLimit, no ctrlF, no interpolate');
      expect(d[2], 0x00, reason: 'SetVal pinned to 0 (locked PREVIOUS)');
      expect(d[3], 0xB8, reason: 'temp 92C');
      expect(d[4], 0x9E, reason: '30s');
      expect(d[5], 0x00, reason: 'no exit trigger');
      expect(d[6], 0x04, reason: 'vol 0 -> U10P0 high byte');
      expect(d[7], 0x00);
    });

    test('HOLD-pressure ext: [.., 0x3C, 0x06, mode=3, 0,0,0,0]', () {
      final d = frames[4].data;
      expect(d[1], 0x3C, reason: 'MaxFlow 6.0');
      expect(d[2], 0x06, reason: 'MaxFlow range 0.6');
      expect(d[3], 0x03, reason: 'Mode = HOLD-pressure');
      expect(d[4], 0x00);
      expect(d[5], 0x00);
      expect(d[6], 0x00);
      expect(d[7], 0x00);
    });

    test('HOLD-flow base: flag 0x41 (ctrlF), SetVal 0', () {
      final d = frames[2].data;
      // ignoreLimit(0x40) | ctrlF(0x01): flow-priority, no interpolate.
      expect(d[1], 0x41, reason: 'flag: ignoreLimit | ctrlF, no interpolate');
      expect(d[2], 0x00, reason: 'SetVal pinned to 0');
    });

    test('HOLD-flow ext: [.., 0x5A, 0x09, mode=4, 0,0,0,0]', () {
      final d = frames[5].data;
      expect(d[1], 0x5A, reason: 'MaxPressure 9.0');
      expect(d[2], 0x09, reason: 'MaxPressure range 0.9');
      expect(d[3], 0x04, reason: 'Mode = HOLD-flow');
      expect(d[4], 0x00);
      expect(d[5], 0x00);
      expect(d[6], 0x00);
      expect(d[7], 0x00);
    });

    test('HOLD-power base: flag 0x40 (pressure-prio), SetVal 0', () {
      final d = frames[3].data;
      expect(d[1], 0x40, reason: 'flag: ignoreLimit, no ctrlF, no interpolate');
      expect(d[2], 0x00, reason: 'SetVal pinned to 0');
    });

    test('HOLD-power ext: [.., 0,0, mode=5, cap=0x5A, 0,0,0]', () {
      final d = frames[6].data;
      expect(d[1], 0x00, reason: 'no flow cap for HOLD-power');
      expect(d[2], 0x00);
      expect(d[3], 0x05, reason: 'Mode = HOLD-power');
      expect(d[4], 0x5A, reason: 'ModeMaxP = mandatory pressure cap 9.0');
      expect(d[5], 0x00);
      expect(d[6], 0x00);
      expect(d[7], 0x00);
    });
  });

  group('HOLD arm-time refusal gate', () {
    // A minimal, VALID (HOLD-not-first) profile with one HOLD-pressure step.
    Profile holdProfile() => const Profile(
      version: '2',
      title: 'hold only',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: [
        ProfileStepFlow(
          name: 'fill',
          transition: TransitionType.fast,
          volume: 0,
          seconds: 5,
          temperature: 92,
          sensor: TemperatureSensor.coffee,
          flow: 8.0,
        ),
        ProfileStepPressure(
          name: 'hold pressure',
          transition: TransitionType.hold,
          volume: 0,
          seconds: 30,
          temperature: 92,
          sensor: TemperatureSensor.coffee,
          pressure: 0,
        ),
      ],
      targetVolumeCountStart: 0,
      tankTemperature: 90,
    );

    Future<UnifiedDe1> connect({
      required int v13Model,
      required int caps,
    }) async {
      final transport = FakeBleTransport();
      final de1 = UnifiedDe1(transport: transport);
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      transport.queueOnConnectResponses(
        v13Model: v13Model,
        profileModeCaps: caps,
      );
      await de1.onConnect();
      addTearDown(transport.dispose);
      return de1;
    }

    test(
      'caps 0x3 (Power|Lever, no HOLD): a HOLD profile is refused',
      () async {
        final de1 = await connect(v13Model: 128, caps: 0x3);
        await expectLater(
          de1.setProfile(holdProfile()),
          throwsA(
            isA<ProfileModeUnsupportedException>().having(
              (e) => e.message,
              'message',
              allOf(contains('HOLD'), contains('does not support')),
            ),
          ),
        );
      },
    );

    test('caps 0x7 (HOLD present): a HOLD profile proceeds', () async {
      final de1 = await connect(v13Model: 128, caps: 0x7);
      await de1.setProfile(holdProfile()); // completes, no throw
    });

    test(
      'DE1 (not Bengle): a HOLD profile is refused before any write',
      () async {
        final de1 = await connect(v13Model: 1, caps: 0x7);
        expect(de1.isBengle, isFalse);
        await expectLater(
          de1.setProfile(holdProfile()),
          throwsA(
            isA<ProfileModeUnsupportedException>().having(
              (e) => e.message,
              'message',
              allOf(contains('HOLD'), contains('not a Bengle')),
            ),
          ),
        );
      },
    );

    test('HOLD as the FIRST step is refused on EVERY machine', () async {
      final de1 = await connect(v13Model: 128, caps: 0x7);
      final firstStepHold = const Profile(
        version: '2',
        title: 'hold first',
        notes: '',
        author: 'test',
        beverageType: BeverageType.espresso,
        steps: [
          ProfileStepPressure(
            name: 'hold pressure',
            transition: TransitionType.hold,
            volume: 0,
            seconds: 30,
            temperature: 92,
            sensor: TemperatureSensor.coffee,
            pressure: 0,
          ),
        ],
        targetVolumeCountStart: 0,
        tankTemperature: 90,
      );
      await expectLater(
        de1.setProfile(firstStepHold),
        throwsA(
          isA<ProfileModeUnsupportedException>().having(
            (e) => e.message,
            'message',
            allOf(contains('first step'), contains('HOLD')),
          ),
        ),
      );
    });
  });
}
