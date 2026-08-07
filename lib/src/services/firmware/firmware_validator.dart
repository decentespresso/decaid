import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:reaprime/src/models/device/firmware_artifact.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/firmware/de1_firmware_header.dart';
import 'package:reaprime/src/services/firmware/firmware_manifest.dart';

final class FirmwareValidator {
  const FirmwareValidator();

  void validate(FirmwareManifestEntry entry, Uint8List image) {
    final artifact = entry.artifact;

    if (image.length != artifact.byteLength) {
      throw FirmwareImageValidationException(
        'Byte length mismatch: manifest says ${artifact.byteLength}, '
        'actual ${image.length}',
      );
    }

    final digest = sha256.convert(image).toString();
    if (digest != artifact.sha256) {
      throw FirmwareImageValidationException(
        'SHA-256 mismatch: manifest says ${artifact.sha256}, '
        'computed $digest',
      );
    }

    final De1FirmwareHeader header;
    try {
      header = De1FirmwareHeader.parse(image);
    } on FormatException catch (error) {
      throw FirmwareImageValidationException(error.message);
    }

    if (!header.isDe1Board) {
      throw FirmwareImageValidationException(
        'Board marker 0x${header.boardMarker.toRadixString(16)} does not '
        'match expected 0x${De1FirmwareHeader.de1BoardMarker.toRadixString(16)}',
      );
    }

    if (header.boardMarker != entry.expectedHeaderBoardMarker) {
      throw FirmwareImageValidationException(
        'Header board marker 0x${header.boardMarker.toRadixString(16)} '
        'mismatches manifest expected 0x${entry.expectedHeaderBoardMarker.toRadixString(16)}',
      );
    }

    if (header.firmwareVersion != artifact.build) {
      throw FirmwareImageValidationException(
        'Header firmware version ${header.firmwareVersion} does not '
        'match manifest build ${artifact.build}',
      );
    }

    if (header.bodyByteCount != entry.expectedBodyByteCount) {
      throw FirmwareImageValidationException(
        'Header body byte count ${header.bodyByteCount} mismatches '
        'manifest expected ${entry.expectedBodyByteCount}',
      );
    }

    if (header.cpuByteCount != entry.expectedCpuByteCount) {
      throw FirmwareImageValidationException(
        'Header CPU byte count ${header.cpuByteCount} mismatches '
        'manifest expected ${entry.expectedCpuByteCount}',
      );
    }

    if (header.bodyByteCount <= 0 ||
        header.bodyByteCount > image.length - De1FirmwareHeader.byteLength) {
      throw FirmwareImageValidationException(
        'Header body byte count ${header.bodyByteCount} is not sane for '
        '${image.length} image bytes',
      );
    }
    if (header.cpuByteCount <= 0 ||
        header.cpuByteCount > header.bodyByteCount) {
      throw FirmwareImageValidationException(
        'Header CPU byte count ${header.cpuByteCount} is not sane for '
        '${header.bodyByteCount} body bytes',
      );
    }
    if (header.unused != 0) {
      throw FirmwareImageValidationException(
        'Reserved header field must be zero',
      );
    }
    if (header.checksum == 0 ||
        header.decryptedChecksum == 0 ||
        header.headerChecksum == 0 ||
        header.initializationVector.every((byte) => byte == 0)) {
      throw FirmwareImageValidationException(
        'Firmware checksum header fields are incomplete',
      );
    }
  }

  FirmwareEligibility evaluateEligibility(
    FirmwareArtifact artifact, {
    String? connectedModel,
    String? installedBuild,
  }) {
    if (connectedModel == null) {
      return const FirmwareEligibility(
        status: FirmwareEligibilityStatus.unknown,
        reasons: ['machine_not_connected'],
      );
    }

    if (connectedModel.isEmpty || connectedModel == 'Unknown') {
      return const FirmwareEligibility(
        status: FirmwareEligibilityStatus.unknown,
        reasons: ['machine_model_unknown'],
      );
    }

    if (!artifact.supportedModels.contains(connectedModel)) {
      return const FirmwareEligibility(
        status: FirmwareEligibilityStatus.notApplicable,
        reasons: ['model_incompatible'],
      );
    }

    if (installedBuild == null) {
      return const FirmwareEligibility(
        status: FirmwareEligibilityStatus.unknown,
        reasons: ['installed_build_unknown'],
      );
    }

    final installedBuildNum = int.tryParse(installedBuild);
    if (installedBuildNum == null) {
      return const FirmwareEligibility(
        status: FirmwareEligibilityStatus.unknown,
        reasons: ['installed_build_unknown'],
      );
    }

    if (artifact.build <= installedBuildNum) {
      return const FirmwareEligibility(
        status: FirmwareEligibilityStatus.notApplicable,
        reasons: ['not_newer'],
      );
    }

    return const FirmwareEligibility(
      status: FirmwareEligibilityStatus.applicable,
    );
  }
}
