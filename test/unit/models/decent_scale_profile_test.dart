import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/profile.dart';

List<int> frame(List<int> bytes) {
  final checksum = bytes.fold(0, (value, byte) => value ^ byte);
  return [...bytes, checksum];
}

void main() {
  group('Decent scale frame parsing', () {
    test('parses original v1.x weight frames', () {
      final parsed = parseDecentWeightFrame(
        frame([0x03, 0xCE, 0x01, 0xF4, 0x00, 0x00]),
      );

      expect(parsed, isNotNull);
      expect(parsed!.weight, 50.0);
      expect(parsed.timestamped, isFalse);
      expect(parsed.timestampMillis, isNull);

      final profile = DecentScaleProfile.fromEvidence(
        statusResponseSeen: true,
        sawTimestampedWeightFrame: false,
        voltageProbeAccepted: false,
      );
      expect(profile.identity, DecentScaleIdentity.originalDecentScale);
      expect(profile.capabilities, DecentScaleCapabilities.conservative);
      expect(profile.capabilities.unreliableCommandBuffer, isTrue);
      expect(profile.capabilities.supportsPowerOff, isFalse);
      expect(profile.capabilities.supportsSoftSleep, isFalse);
    });

    test('parses original v1.2 timestamped weight frames', () {
      final parsed = parseDecentWeightFrame(
        frame([0x03, 0xCE, 0x01, 0xF4, 0x01, 0x02, 0x03, 0x00, 0x00]),
      );

      expect(parsed, isNotNull);
      expect(parsed!.weight, 50.0);
      expect(parsed.timestamped, isTrue);
      expect(parsed.timestampMillis, 62300);

      final profile = DecentScaleProfile.fromEvidence(
        statusResponseSeen: false,
        sawTimestampedWeightFrame: true,
        voltageProbeAccepted: false,
      );
      expect(profile.identity, DecentScaleIdentity.originalDecentScale);
      expect(profile.capabilities, DecentScaleCapabilities.originalTimestamped);
      expect(profile.capabilities.supportsPowerOff, isTrue);
      expect(profile.capabilities.unreliableCommandBuffer, isFalse);
    });

    test('decodes original firmware markers and capabilities', () {
      final v10 = DecentScaleProfile.fromEvidence(
        statusResponseSeen: true,
        sawTimestampedWeightFrame: false,
        voltageProbeAccepted: false,
        originalFirmwareMarker: 0xFE,
      );
      expect(v10.originalFirmwareVersion, '1.0');
      expect(v10.capabilities, DecentScaleCapabilities.conservative);

      final v11 = DecentScaleProfile.fromEvidence(
        statusResponseSeen: true,
        sawTimestampedWeightFrame: false,
        voltageProbeAccepted: false,
        originalFirmwareMarker: 0x02,
      );
      expect(v11.originalFirmwareVersion, '1.1');
      expect(v11.capabilities, DecentScaleCapabilities.originalReliable);
      expect(v11.capabilities.unreliableCommandBuffer, isFalse);
      expect(v11.capabilities.supportsPowerOff, isFalse);

      final v12 = DecentScaleProfile.fromEvidence(
        statusResponseSeen: true,
        sawTimestampedWeightFrame: false,
        voltageProbeAccepted: false,
        originalFirmwareMarker: 0x03,
      );
      expect(v12.originalFirmwareVersion, '1.2');
      expect(v12.capabilities.supportsPowerOff, isTrue);
      expect(v12.capabilities.unreliableCommandBuffer, isFalse);
    });

    test('parses HDS voltage and derives HDS capabilities', () {
      final parsed = parseDecentVoltageFrame(
        frame([0x03, 0x22, 0x01, 0x89, 0x00, 0x00]),
      );

      expect(parsed, isNotNull);
      expect(parsed!.voltage, 39.3);

      final profile = DecentScaleProfile.fromEvidence(
        statusResponseSeen: true,
        sawTimestampedWeightFrame: false,
        voltageProbeAccepted: true,
        originalFirmwareMarker: 0x02,
      );
      expect(profile.identity, DecentScaleIdentity.halfDecentScale);
      expect(profile.capabilities, DecentScaleCapabilities.hdsExtended);
      expect(profile.capabilities.supportsSoftSleep, isFalse);
      expect(profile.capabilities.supportsHdsExtendedCommands, isTrue);
      expect(profile.isHds, isTrue);
      expect(profile.originalFirmwareVersion, isNull);
    });

    test('rejects corrupt capability evidence checksums', () {
      expect(
        parseDecentVoltageFrame([0x03, 0x22, 0x01, 0x89, 0x00, 0x00, 0xAB]),
        isNull,
      );
      expect(
        parseDecentWeightFrame([
          0x03,
          0xCE,
          0x00,
          0x64,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
        ]),
        isNull,
      );
    });

    test('does not infer HDS without an accepted voltage probe', () {
      final profile = DecentScaleProfile.fromEvidence(
        statusResponseSeen: false,
        sawTimestampedWeightFrame: false,
        voltageProbeAccepted: false,
      );

      expect(profile.identity, DecentScaleIdentity.unknown);
      expect(profile.capabilities, DecentScaleCapabilities.conservative);
      expect(profile.isHds, isFalse);
    });

    test('parses modern HDS status and rejects non-BCD firmware', () {
      final modern = parseDecentStatusFrame([
        0x03,
        0x0A,
        0x00,
        0x00,
        80,
        0x02,
        0x58,
      ]);
      expect(modern, isNotNull);
      expect(modern!.hdsFirmwareVersion.toString(), '2.5.8');
      expect(modern.originalFirmwareMarker, 0x02);

      final invalid = parseDecentStatusFrame([
        0x03,
        0x0A,
        0x00,
        0x00,
        80,
        0x1F,
        0x1D,
      ]);
      expect(invalid, isNotNull);
      expect(invalid!.hdsFirmwareVersion, isNull);
      expect(invalid.originalFirmwareMarker, 0x1F);
    });

    test('derives soft sleep for modern HDS firmware', () {
      final profile = DecentScaleProfile.fromEvidence(
        statusResponseSeen: true,
        sawTimestampedWeightFrame: false,
        voltageProbeAccepted: true,
        hdsFirmwareVersion: DecentHdsFirmwareVersion.fromBcd(0x03, 0x1E),
      );

      expect(profile.hdsFirmwareVersion.toString(), '3.1.14');
      expect(profile.capabilities, DecentScaleCapabilities.halfDecent);
      expect(profile.capabilities.supportsSoftSleep, isTrue);
    });

    test('does not enable soft sleep for HDS firmware before 3.x', () {
      final profile = DecentScaleProfile.fromEvidence(
        statusResponseSeen: true,
        sawTimestampedWeightFrame: false,
        voltageProbeAccepted: true,
        hdsFirmwareVersion: DecentHdsFirmwareVersion.fromBcd(0x02, 0x58),
      );

      expect(profile.capabilities, DecentScaleCapabilities.hdsExtended);
      expect(profile.capabilities.supportsSoftSleep, isFalse);
    });

    test('decodes packed HDS firmware minor and patch nibbles', () {
      expect(DecentHdsFirmwareVersion.fromBcd(0x03, 0x1E).toString(), '3.1.14');
      expect(DecentHdsFirmwareVersion.fromBcd(0x02, 0x1D).toString(), '2.1.13');
      expect(DecentHdsFirmwareVersion.fromBcd(0xA1, 0x00), isNull);
    });

    test('rejects implausible HDS firmware majors', () {
      expect(DecentHdsFirmwareVersion.fromBcd(0x31, 0x00), isNull);
      expect(DecentHdsFirmwareVersion.fromBcd(0x99, 0x00), isNull);
    });

    test('rejects malformed and ambiguous frames', () {
      expect(parseDecentStatusFrame(const []), isNull);
      expect(parseDecentStatusFrame([0x04, 0x0A, 0, 0, 0, 0, 0]), isNull);
      expect(parseDecentStatusFrame([0x03, 0x0A, 0, 0, 0, 0]), isNull);
      expect(parseDecentWeightFrame([0x03, 0xAA, 0, 0, 0, 0, 0]), isNull);
      expect(parseDecentVoltageFrame([0x03, 0x22, 0, 0, 0, 0, 0, 0]), isNull);
      expect(parseDecentWeightFrame([0x03, 0xCE, 0, 0, 0, 0, 0, 0]), isNull);

      final profile = DecentScaleProfile.fromEvidence(
        statusResponseSeen: false,
        sawTimestampedWeightFrame: false,
        voltageProbeAccepted: false,
      );
      expect(profile.identity, DecentScaleIdentity.unknown);
      expect(profile.capabilities, DecentScaleCapabilities.conservative);
    });

    test('handles charging status and negative weight', () {
      final status = parseDecentStatusFrame([
        0x03,
        0x0A,
        0x00,
        0x00,
        0xFF,
        0x02,
        0x58,
      ]);
      expect(status, isNotNull);
      expect(status!.charging, isTrue);
      expect(status.batteryByte, 0xFF);
      expect(status.batteryLevel, 100);

      final weight = parseDecentWeightFrame(
        frame([0x03, 0xCA, 0xFF, 0x9C, 0x00, 0x00]),
      );
      expect(weight, isNotNull);
      expect(weight!.weight, -10.0);
    });

    test('accepts production fixtures with bogus trailing bytes', () {
      final weight = parseDecentWeightFrame([
        0x03,
        0xCE,
        0x00,
        100,
        0x00,
        0x00,
        0x00,
      ]);
      expect(weight, isNotNull);
      expect(weight!.weight, 10.0);

      final status = parseDecentStatusFrame([
        0x03,
        0x0A,
        0x00,
        0x00,
        73,
        0x03,
        0x1D,
      ]);
      expect(status, isNotNull);
      expect(status!.batteryLevel, 73);
    });

    test('labels contain enabled capabilities in sorted order', () {
      expect(DecentScaleCapabilities.hdsExtended.labels, [
        'hdsExtendedCommands',
        'powerOff',
      ]);
      expect(DecentScaleCapabilities.halfDecent.labels, [
        'hdsExtendedCommands',
        'powerOff',
        'softSleep',
      ]);
      expect(DecentScaleCapabilities.conservative.labels, [
        'unreliableCommandBuffer',
      ]);
      expect(DecentScaleCapabilities.originalTimestamped.labels, [
        'powerOff',
        'timestampedWeightFrames',
      ]);
    });
  });
}
