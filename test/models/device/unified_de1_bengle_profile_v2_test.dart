import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import '../../helpers/fake_ble_transport.dart';

Profile _representativeProfile() => const Profile(
  version: '2',
  title: 'v1/v2 byte test',
  notes: '',
  author: 'test',
  beverageType: BeverageType.espresso,
  steps: [
    ProfileStepFlow(
      name: 'preinfuse',
      flow: 6.0,
      seconds: 15,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.smooth,
      volume: 0,
      exit: StepExitCondition(
        type: ExitType.flow,
        condition: ExitCondition.over,
        value: 4.0,
      ),
      limiter: StepLimiter(value: 8.0, range: 2.0),
    ),
    ProfileStepPressure(
      name: 'pour',
      pressure: 9.0,
      seconds: 30,
      temperature: 92,
      sensor: TemperatureSensor.coffee,
      transition: TransitionType.fast,
      volume: 0,
    ),
  ],
  targetVolumeCountStart: 0,
  tankTemperature: 93,
);

/// Returns ordered profile payloads — header + frames + tail — from [writes],
/// filtering out MMR writes (`A006`).
List<Uint8List> profilePayloads(List<FakeBleWrite> writes) => writes
    .where(
      (w) =>
          w.characteristicUUID == Endpoint.headerWrite.uuid ||
          w.characteristicUUID == Endpoint.frameWrite.uuid,
    )
    .map((w) => w.data)
    .toList();

void main() {
  group('DE1 profile v1 golden', () {
    late FakeBleTransport transport;
    late UnifiedDe1 de1;

    setUp(() {
      transport = FakeBleTransport();
      de1 = UnifiedDe1(transport: transport);
    });

    tearDown(() {
      transport.dispose();
    });

    test('emits header v1 and 1/16 flow/pressure bytes', () async {
      await de1.setProfile(_representativeProfile());

      final payloads = profilePayloads(transport.writes);
      expect(
        payloads.length,
        greaterThanOrEqualTo(5),
        reason: 'header + 2 frames + 1 extension + tail',
      );

      final header = payloads[0];
      expect(header, hasLength(5));
      expect(header[0], 1, reason: 'header version');
      expect(header[1], 2, reason: 'step count');
      expect(header[2], 0, reason: 'targetVolumeCountStart');
      expect(header[3], 0, reason: 'minimum pressure');
      expect(header[4], 192, reason: 'max flow 12 × 16 = 0xC0');

      final frame0 = payloads[1];
      expect(frame0, hasLength(8));
      expect(frame0[0], 0, reason: 'frame index');
      expect(frame0[2], 96, reason: 'flow target 6 × 16 = 0x60');
      expect(frame0[3], 184, reason: 'temp 92 × 2 = 184');
      expect(frame0[5], 64, reason: 'trigger 4 × 16 = 0x40');

      // Frame 1 (pressure step) — written before extension frames
      final frame1 = payloads[2];
      expect(frame1, hasLength(8));
      expect(frame1[0], 1, reason: 'frame index');
      expect(frame1[2], 144, reason: 'pressure target 9 × 16 = 0x90');
      expect(frame1[5], 0, reason: 'no exit trigger');

      final ext0 = payloads[3];
      expect(ext0, hasLength(8));
      expect(ext0[0], 32, reason: 'extension index');
      expect(ext0[1], 128, reason: 'limiter 8 × 16 = 0x80');
      expect(ext0[2], 32, reason: 'limiter range 2 × 16 = 0x20');

      final tail = payloads[4];
      expect(tail, hasLength(8));
      expect(tail[0], 2, reason: 'step count in tail');
      expect(tail.sublist(1), everyElement(0), reason: 'tail padding');
    });

    test('rounding: 9.25 * 16 = 148 (not 149)', () async {
      final profile = const Profile(
        version: '2',
        title: 'rounding',
        notes: '',
        author: 'test',
        beverageType: BeverageType.espresso,
        steps: [
          ProfileStepFlow(
            name: 'x',
            flow: 9.25,
            seconds: 10,
            temperature: 90,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
        ],
        targetVolumeCountStart: 0,
        tankTemperature: 90,
      );
      await de1.setProfile(profile);
      final payloads = profilePayloads(transport.writes);
      expect(payloads[1][2], 148, reason: '(0.5 + 9.25 * 16).toInt() = 148');
    });
  });

  group('Bengle profile v2', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    setUp(() {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
    });

    tearDown(() {
      transport.dispose();
    });

    test('emits header v2 and 1/10 flow/pressure bytes', () async {
      await bengle.setProfile(_representativeProfile());

      final payloads = profilePayloads(transport.writes);
      expect(payloads.length, greaterThanOrEqualTo(5));

      final header = payloads[0];
      expect(header[0], 2, reason: 'header version v2 for Bengle');
      expect(header[1], 2, reason: 'step count');
      expect(header[3], 0, reason: 'minimum pressure 0 × 10 = 0x00');
      expect(header[4], 120, reason: 'max flow 12 × 10 = 0x78');

      final frame0 = payloads[1];
      expect(frame0[2], 60, reason: 'flow target 6 × 10 = 0x3C');
      expect(frame0[5], 40, reason: 'trigger 4 × 10 = 0x28');

      final frame1 = payloads[2];
      expect(frame1[2], 90, reason: 'pressure target 9 × 10 = 0x5A');

      final ext0 = payloads[3];
      expect(ext0[1], 80, reason: 'limiter 8 × 10 = 0x50');
      expect(ext0[2], 20, reason: 'limiter range 2 × 10 = 0x14');

      expect(frame0[3], 184, reason: 'temperature unchanged');
      expect(frame1[3], 184, reason: 'temperature unchanged');
      expect(payloads[4][0], 2, reason: 'tail unchanged');
    });

    test('rounding: 9.25 * 10 = 92.5 → 93', () async {
      final profile = const Profile(
        version: '2',
        title: 'rounding',
        notes: '',
        author: 'test',
        beverageType: BeverageType.espresso,
        steps: [
          ProfileStepFlow(
            name: 'x',
            flow: 9.25,
            seconds: 10,
            temperature: 90,
            sensor: TemperatureSensor.coffee,
            transition: TransitionType.fast,
            volume: 0,
          ),
        ],
        targetVolumeCountStart: 0,
        tankTemperature: 90,
      );
      await bengle.setProfile(profile);
      final payloads = profilePayloads(transport.writes);
      expect(payloads[1][2], 93, reason: '(0.5 + 9.25 * 10).toInt() = 93');
    });

    test('withResponse flag is true on all profile writes', () async {
      await bengle.setProfile(_representativeProfile());
      final profileWrites = transport.writes.where(
        (w) =>
            w.characteristicUUID == Endpoint.headerWrite.uuid ||
            w.characteristicUUID == Endpoint.frameWrite.uuid,
      );
      for (final w in profileWrites) {
        expect(
          w.withResponse,
          isTrue,
          reason: '${w.characteristicUUID} must use writeWithResponse',
        );
      }
    });
  });
}
