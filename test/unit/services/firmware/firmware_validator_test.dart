import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/firmware_artifact.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/firmware/bundled_firmware_catalog.dart';
import 'package:reaprime/src/services/firmware/firmware_manifest.dart';
import 'package:reaprime/src/services/firmware/firmware_validator.dart';

Uint8List _buildImage({
  int boardMarker = 0xDE100001,
  int firmwareVersion = 1356,
  int bodyByteCount = 100,
  int cpuByteCount = 20,
  int totalSize = 200,
}) {
  final bytes = Uint8List(totalSize);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, 0x11223344, Endian.little);
  view.setUint32(4, boardMarker, Endian.little);
  view.setUint32(8, firmwareVersion, Endian.little);
  view.setUint32(12, bodyByteCount, Endian.little);
  view.setUint32(16, cpuByteCount, Endian.little);
  view.setUint32(24, 0x55667788, Endian.little);
  for (var i = 28; i < 60; i++) {
    bytes[i] = i;
  }
  view.setUint32(60, 0x99AABBCC, Endian.little);
  return bytes;
}

FirmwareManifestEntry _entryForImage(
  Uint8List image, {
  String id = 'de1-1356',
  int build = 1356,
  int bodyByteCount = 100,
  int cpuByteCount = 20,
  int boardMarker = 0xDE100001,
}) {
  final digest = sha256.convert(image).toString();
  return FirmwareManifestEntry(
    artifact: FirmwareArtifact(
      id: id,
      source: FirmwareArtifactSource.bundled,
      machineFamily: 'de1',
      supportedModels: const {'DE1Pro', 'DE1XL'},
      build: build,
      versionLabel: '$build',
      imageFormat: 'de1',
      byteLength: image.length,
      sha256: digest,
      channel: 'stable',
      releaseNotes: 'Test firmware.',
    ),
    assetPath: 'assets/firmware/de1/$id.bin',
    expectedHeaderBoardMarker: boardMarker,
    expectedBodyByteCount: bodyByteCount,
    expectedCpuByteCount: cpuByteCount,
    provenance: 'Test build.',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FirmwareValidator.validate', () {
    final validator = const FirmwareValidator();

    test('valid image passes all checks', () {
      final image = _buildImage();
      final entry = _entryForImage(image);
      expect(() => validator.validate(entry, image), returnsNormally);
    });

    test('length mismatch throws', () {
      final image = _buildImage();
      final entry = _entryForImage(image);
      final truncated = Uint8List.sublistView(image, 0, image.length - 1);
      expect(
        () => validator.validate(entry, truncated),
        throwsA(
          predicate(
            (e) =>
                e is FirmwareImageValidationException &&
                e.reason.contains('Byte length'),
          ),
        ),
      );
    });

    test('SHA-256 mismatch throws', () {
      final image = _buildImage();
      final entry = _entryForImage(image);
      final modified = Uint8List.fromList(image);
      modified[modified.length - 1] ^= 0xFF;
      expect(
        () => validator.validate(entry, modified),
        throwsA(
          predicate(
            (e) =>
                e is FirmwareImageValidationException &&
                e.reason.contains('SHA-256'),
          ),
        ),
      );
    });

    test('wrong board marker throws', () {
      final image = _buildImage(boardMarker: 0x12345678);
      final entry = _entryForImage(image, boardMarker: 0xDE100001);
      expect(
        () => validator.validate(entry, image),
        throwsA(
          predicate(
            (e) =>
                e is FirmwareImageValidationException &&
                e.reason.contains('Board marker'),
          ),
        ),
      );
    });

    test('header build mismatch throws', () {
      final image = _buildImage(firmwareVersion: 9999);
      final entry = _entryForImage(image);
      expect(
        () => validator.validate(entry, image),
        throwsA(
          predicate(
            (e) =>
                e is FirmwareImageValidationException &&
                e.reason.contains('firmware version'),
          ),
        ),
      );
    });

    test('body byte count cannot exceed bytes after the header', () {
      final image = _buildImage(bodyByteCount: 1000);
      final entry = _entryForImage(image, bodyByteCount: 1000);
      expect(
        () => validator.validate(entry, image),
        throwsA(isA<FirmwareImageValidationException>()),
      );
    });

    test('CPU byte count cannot exceed body byte count', () {
      final image = _buildImage(bodyByteCount: 100, cpuByteCount: 101);
      final entry = _entryForImage(
        image,
        bodyByteCount: 100,
        cpuByteCount: 101,
      );
      expect(
        () => validator.validate(entry, image),
        throwsA(isA<FirmwareImageValidationException>()),
      );
    });
  });

  group('FirmwareValidator.evaluateEligibility', () {
    final validator = const FirmwareValidator();
    final artifact = FirmwareArtifact(
      id: 'de1-1356',
      source: FirmwareArtifactSource.bundled,
      machineFamily: 'de1',
      supportedModels: const {'DE1Pro', 'DE1XL'},
      build: 1356,
      versionLabel: '1356',
      imageFormat: 'de1',
      byteLength: 100,
      sha256:
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      channel: 'stable',
      releaseNotes: '',
    );

    test('unknown when no machine connected', () {
      final eligibility = validator.evaluateEligibility(artifact);
      expect(eligibility.status, FirmwareEligibilityStatus.unknown);
      expect(eligibility.reasons, contains('machine_not_connected'));
    });

    test('notApplicable when model incompatible', () {
      final eligibility = validator.evaluateEligibility(
        artifact,
        connectedModel: 'DE1CAFE',
        installedBuild: '1300',
      );
      expect(eligibility.status, FirmwareEligibilityStatus.notApplicable);
      expect(eligibility.reasons, contains('model_incompatible'));
    });

    test('applicable when installed build is older', () {
      final eligibility = validator.evaluateEligibility(
        artifact,
        connectedModel: 'DE1Pro',
        installedBuild: '1300',
      );
      expect(eligibility.status, FirmwareEligibilityStatus.applicable);
      expect(eligibility.reasons, isEmpty);
    });

    test('notApplicable when installed build equals artifact build', () {
      final eligibility = validator.evaluateEligibility(
        artifact,
        connectedModel: 'DE1Pro',
        installedBuild: '1356',
      );
      expect(eligibility.status, FirmwareEligibilityStatus.notApplicable);
      expect(eligibility.reasons, contains('not_newer'));
    });

    test('notApplicable when installed build is newer', () {
      final eligibility = validator.evaluateEligibility(
        artifact,
        connectedModel: 'DE1Pro',
        installedBuild: '1400',
      );
      expect(eligibility.status, FirmwareEligibilityStatus.notApplicable);
      expect(eligibility.reasons, contains('not_newer'));
    });

    test('unknown when installed build is non-numeric', () {
      final eligibility = validator.evaluateEligibility(
        artifact,
        connectedModel: 'DE1Pro',
        installedBuild: 'beta',
      );
      expect(eligibility.status, FirmwareEligibilityStatus.unknown);
      expect(eligibility.reasons, contains('installed_build_unknown'));
    });
  });

  test(
    'production bundled artifacts allow canonical models at build 1333',
    () async {
      final catalog = BundledFirmwareCatalog(bundle: rootBundle);
      final manifest = await catalog.loadManifest();
      final validator = const FirmwareValidator();

      for (final entry in manifest.entries) {
        expect(entry.artifact.build, anyOf(1352, 1358));
        for (final model in ['DE1', 'DE1Plus', 'DE1Cafe']) {
          final eligibility = validator.evaluateEligibility(
            entry.artifact,
            connectedModel: model,
            installedBuild: '1333',
          );
          expect(eligibility.status, FirmwareEligibilityStatus.applicable);
          expect(eligibility.reasons, isEmpty);
        }
      }
    },
  );
}
