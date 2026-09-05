import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/errors.dart';

import '../../helpers/fake_ble_transport.dart';

/// Byte-exact ext-frame encoding for the additive Power / Lever pump modes,
/// plus the capability refusal gate. A real [UnifiedDe1] over
/// [FakeBleTransport], connected as a Bengle (`v13Model = 128`) that advertises
/// the caps mask.
///
/// New-mode steps are NOT ProfileStepFlow, so `CtrlF` stays 0 (pressure
/// priority) and the base-frame SetVal already encodes W / P₀ via the shared
/// U8D1 path. The ext frame is what carries the mode:
///   data[3] = mode (1 Power, 2 Lever)
///   data[4] = ModeMaxP (Power: pressure cap; Lever: P₀ == base SetVal byte)
///   data[5] = leverSpring (U8D1)   data[6] = leverGive (U8D1)   data[7] = 0
///   data[1]/[2] = stock limiter (Power 0/0; Lever flow cap value/range or 0/0)
///
/// Golden bytes (U8D1 = value×10):
///   power 2.0 W          -> base SetVal 0x14
///   pressure/P₀ 9.0 bar  -> 0x5A
///   pressure/P₀ 8.0 bar  -> 0x50
///   flow cap 6.0 ml/s    -> 0x3C     range 0.6 -> 0x06
///   leverSpring 0.9      -> 0x09     leverGive 1.5 -> 0x0F     2.5 -> 0x19
void main() {
  // Frame 0: Power 2.0 W with the mandatory 9.0-bar pressure cap.
  // Frame 1: Lever P₀ 9.0 (CLASSIC), spring 0.9, give 1.5, WITH a 6.0 ml/s
  //          flow cap.
  // Frame 2: Lever P₀ 8.0, spring 0.6, give 2.5, WITHOUT a flow cap (0/0).
  const profile = Profile(
    version: '2',
    title: 'encoder profile',
    notes: '',
    author: 'test',
    beverageType: BeverageType.espresso,
    steps: [
      ProfileStepPower(
        name: 'power',
        transition: TransitionType.fast,
        volume: 0,
        seconds: 10,
        temperature: 92,
        sensor: TemperatureSensor.coffee,
        power: 2.0,
        limiter: StepLimiter(value: 9.0, range: 0.6),
      ),
      ProfileStepLever(
        name: 'lever-capped',
        transition: TransitionType.smooth,
        volume: 0,
        seconds: 30,
        temperature: 90,
        sensor: TemperatureSensor.coffee,
        pressure: 9.0,
        leverSpring: 0.9,
        leverGive: 1.5,
        limiter: StepLimiter(value: 6.0, range: 0.6),
      ),
      ProfileStepLever(
        name: 'lever-uncapped',
        transition: TransitionType.fast,
        volume: 0,
        seconds: 30,
        temperature: 90,
        sensor: TemperatureSensor.coffee,
        pressure: 8.0,
        leverSpring: 0.6,
        leverGive: 2.5,
      ),
    ],
    targetVolumeCountStart: 0,
    tankTemperature: 0,
  );

  Future<List<FakeBleWrite>> uploadFrames() async {
    final transport = FakeBleTransport();
    final de1 = UnifiedDe1(transport: transport);
    transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
    // Advertise both Power and Lever so the refusal gate lets this proceed.
    transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: 0x3);
    await de1.onConnect();
    await de1.setProfile(profile);
    final frames = transport.writes
        .where((w) => w.characteristicUUID == Endpoint.frameWrite.uuid)
        .toList();
    await transport.dispose();
    return frames;
  }

  group('Bengle ext-frame encoding', () {
    late List<FakeBleWrite> frames;

    setUpAll(() async {
      frames = await uploadFrames();
    });

    test('sequence = 3 base + 3 ext + tail, in order', () {
      expect(frames, hasLength(7));
      expect(frames[0].data[0], 0, reason: 'base frame 0');
      expect(frames[1].data[0], 1, reason: 'base frame 1');
      expect(frames[2].data[0], 2, reason: 'base frame 2');
      expect(frames[3].data[0], 32, reason: 'ext frame step 0');
      expect(frames[4].data[0], 33, reason: 'ext frame step 1');
      expect(frames[5].data[0], 34, reason: 'ext frame step 2');
      expect(frames[6].data[0], 3, reason: 'tail = steps.length');
    });

    test('base SetVal: power 2.0 W -> 0x14', () {
      expect(frames[0].data[2], 0x14);
    });

    test('base flag byte: power step keeps CtrlF=0 (pressure priority)', () {
      // ignoreLimit(0x40) only — no CtrlF(0x01), no interpolate (fast).
      expect(frames[0].data[1], 0x40);
    });

    test('base SetVal: lever P0 9.0 -> 0x5A, 8.0 -> 0x50', () {
      expect(frames[1].data[2], 0x5A);
      expect(frames[2].data[2], 0x50);
    });

    test(
      'base flag byte: lever step keeps CtrlF=0 (smooth adds interpolate)',
      () {
        // ignoreLimit(0x40) | interpolate(0x20) = 0x60, still no CtrlF.
        expect(frames[1].data[1], 0x60);
      },
    );

    test('power ext frame: [0,0, mode=1, cap=0x5A, 0,0,0]', () {
      final d = frames[3].data;
      expect(d[1], 0x00, reason: 'no flow cap for Power');
      expect(d[2], 0x00);
      expect(d[3], 0x01, reason: 'Mode = Power');
      expect(d[4], 0x5A, reason: 'ModeMaxP = pressure cap 9.0');
      expect(d[5], 0x00);
      expect(d[6], 0x00);
      expect(d[7], 0x00);
    });

    test(
      'lever ext frame (capped): [0x3C,0x06, mode=2, 0x5A, 0x09,0x0F, 0]',
      () {
        final d = frames[4].data;
        expect(d[1], 0x3C, reason: 'flow cap 6.0');
        expect(d[2], 0x06, reason: 'flow cap range 0.6');
        expect(d[3], 0x02, reason: 'Mode = Lever');
        expect(d[4], 0x5A, reason: 'ModeMaxP = P0 9.0 (== base SetVal)');
        expect(d[5], 0x09, reason: 'leverSpring 0.9');
        expect(d[6], 0x0F, reason: 'leverGive 1.5');
        expect(d[7], 0x00);
      },
    );

    test('lever ext frame (uncapped): flow cap 0/0, mode=2, P0=0x50', () {
      final d = frames[5].data;
      expect(d[1], 0x00, reason: 'no flow cap -> 0');
      expect(d[2], 0x00);
      expect(d[3], 0x02, reason: 'Mode = Lever');
      expect(d[4], 0x50, reason: 'ModeMaxP = P0 8.0');
      expect(d[5], 0x06, reason: 'leverSpring 0.6');
      expect(d[6], 0x19, reason: 'leverGive 2.5');
      expect(d[7], 0x00);
    });
  });

  group('a new-mode step on a non-Bengle is refused before any write', () {
    test('a plain DE1 (not Bengle) with garbage caps is refused at the gate — '
        'no frames reach the wire', () async {
      final transport = FakeBleTransport();
      final de1 = UnifiedDe1(transport: transport);
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      // A DE1 with the caps bits force-set (impossible in the field, but it
      // exercises the garbage-caps hole): even though the mask passes the caps
      // check, isBengle is false, so the gate refuses BEFORE any BLE write —
      // connect as model 1 so isBengle stays false.
      transport.queueOnConnectResponses(v13Model: 1, profileModeCaps: 0x3);
      await de1.onConnect();
      expect(de1.isBengle, isFalse);
      await expectLater(
        de1.setProfile(profile),
        throwsA(isA<ProfileModeUnsupportedException>()),
      );
      // The refusal fires before the encoder runs, so no header/base frames
      // were written — no half-written profile stranded on the wire.
      expect(
        transport.writes
            .where((w) => w.characteristicUUID == Endpoint.frameWrite.uuid)
            .isEmpty,
        isTrue,
        reason: 'gate must refuse before any frame write (no half-write)',
      );
      await transport.dispose();
    });
  });

  group('capability refusal gate (setProfile)', () {
    Profile leverProfile() => const Profile(
      version: '2',
      title: 'lever only',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: [
        ProfileStepLever(
          name: 'lever',
          transition: TransitionType.smooth,
          volume: 0,
          seconds: 30,
          temperature: 92,
          sensor: TemperatureSensor.coffee,
          pressure: 9.0,
          leverSpring: 0.9,
          leverGive: 1.5,
        ),
      ],
      targetVolumeCountStart: 0,
      tankTemperature: 90,
    );

    Profile powerProfile() => const Profile(
      version: '2',
      title: 'power only',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: [
        ProfileStepPower(
          name: 'power',
          transition: TransitionType.smooth,
          volume: 0,
          seconds: 25,
          temperature: 93,
          sensor: TemperatureSensor.coffee,
          power: 2.0,
          limiter: StepLimiter(value: 9.0, range: 0.6),
        ),
      ],
      targetVolumeCountStart: 0,
      tankTemperature: 90,
    );

    Future<UnifiedDe1> connect(int caps) async {
      final transport = FakeBleTransport();
      final de1 = UnifiedDe1(transport: transport);
      transport.queueMmrResponseInt(MMRItem.calFlowEst, 100);
      transport.queueOnConnectResponses(v13Model: 128, profileModeCaps: caps);
      await de1.onConnect();
      addTearDown(transport.dispose);
      return de1;
    }

    test('caps 0: a lever profile is refused with a typed exception', () async {
      final de1 = await connect(0);
      expect(de1.machineInfo.extra['profileModeCaps'], 0);
      await expectLater(
        de1.setProfile(leverProfile()),
        throwsA(
          isA<ProfileModeUnsupportedException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Lever'), contains('does not support')),
          ),
        ),
      );
    });

    test('caps 0: a power profile is refused with a typed exception', () async {
      final de1 = await connect(0);
      await expectLater(
        de1.setProfile(powerProfile()),
        throwsA(
          isA<ProfileModeUnsupportedException>().having(
            (e) => e.message,
            'message',
            contains('Power'),
          ),
        ),
      );
    });

    test('caps 0x3: both proceed (no throw)', () async {
      final de1 = await connect(0x3);
      expect(de1.machineInfo.extra['profileModeCaps'], 0x3);
      await de1.setProfile(leverProfile()); // completes
      await de1.setProfile(powerProfile()); // completes
    });

    test('caps 0x1 (Power only): power proceeds, lever refused', () async {
      final de1 = await connect(0x1);
      await de1.setProfile(powerProfile()); // completes
      await expectLater(
        de1.setProfile(leverProfile()),
        throwsA(isA<ProfileModeUnsupportedException>()),
      );
    });

    test('caps 0x2 (Lever only): lever proceeds, power refused', () async {
      final de1 = await connect(0x2);
      await de1.setProfile(leverProfile()); // completes
      await expectLater(
        de1.setProfile(powerProfile()),
        throwsA(isA<ProfileModeUnsupportedException>()),
      );
    });
  });
}
