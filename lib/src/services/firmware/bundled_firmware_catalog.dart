import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/firmware/firmware_manifest.dart';
import 'package:reaprime/src/services/firmware/firmware_validator.dart';

final class BundledFirmwareCatalog {
  final AssetBundle _bundle;
  final Logger _log;

  BundledFirmwareCatalog({required AssetBundle bundle, Logger? logger})
    : _bundle = bundle,
      _log = logger ?? Logger('BundledFirmwareCatalog');

  Future<FirmwareManifest> loadManifest() async {
    _log.info('Loading bundled firmware manifest');
    final data = await _bundle.loadString('assets/firmware/manifest.json');
    return FirmwareManifest.parse(data);
  }

  Future<Uint8List> loadImage(String artifactId) async {
    final manifest = await loadManifest();
    final entry = manifest.entries.firstWhere(
      (e) => e.artifact.id == artifactId,
      orElse: () => throw ArgumentError('Unknown artifact ID: $artifactId'),
    );
    final bytes = await _bundle.load(entry.assetPath);
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  }

  Future<void> verifyAllArtifacts() async {
    final manifest = await loadManifest();
    for (final entry in manifest.entries) {
      final bytes = await _bundle.load(entry.assetPath);
      final image = bytes.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
      const FirmwareValidator().validate(entry, image);
    }
    _log.info('All ${manifest.entries.length} firmware artifacts verified');
  }
}
