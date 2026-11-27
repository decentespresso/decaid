import 'dart:typed_data';

enum De1FirmwareImageClassification {
  canonicalDe1,
  unrecognizedAtLeastHeader,
  unrecognizedShort,
}

final class De1FirmwareHeader {
  static const int byteLength = 64;
  static const int maxUploadByteLength = 16 * 1024 * 1024;
  static const int de1BoardMarker = 0xDE100001;

  final int checksum;
  final int boardMarker;
  final int firmwareVersion;
  final int bodyByteCount;
  final int cpuByteCount;
  final int unused;
  final int decryptedChecksum;
  final Uint8List initializationVector;
  final int headerChecksum;

  const De1FirmwareHeader({
    required this.checksum,
    required this.boardMarker,
    required this.firmwareVersion,
    required this.bodyByteCount,
    required this.cpuByteCount,
    required this.unused,
    required this.decryptedChecksum,
    required this.initializationVector,
    required this.headerChecksum,
  });

  factory De1FirmwareHeader.parse(Uint8List image) {
    if (image.length < byteLength) {
      throw const FormatException('Firmware image is shorter than its header');
    }
    final view = ByteData.sublistView(image);
    return De1FirmwareHeader(
      checksum: view.getUint32(0, Endian.little),
      boardMarker: view.getUint32(4, Endian.little),
      firmwareVersion: view.getUint32(8, Endian.little),
      bodyByteCount: view.getUint32(12, Endian.little),
      cpuByteCount: view.getUint32(16, Endian.little),
      unused: view.getUint32(20, Endian.little),
      decryptedChecksum: view.getUint32(24, Endian.little),
      initializationVector: Uint8List.sublistView(image, 28, 60),
      headerChecksum: view.getUint32(60, Endian.little),
    );
  }

  bool get isDe1Board => boardMarker == de1BoardMarker;

  static De1FirmwareImageClassification validateUpload(Uint8List image) {
    if (image.isEmpty) {
      throw const FormatException('Firmware image is empty');
    }
    if (image.length > maxUploadByteLength) {
      throw FormatException(
        'Firmware image exceeds $maxUploadByteLength bytes',
      );
    }
    if (image.length < byteLength) {
      return De1FirmwareImageClassification.unrecognizedShort;
    }

    final boardMarker = ByteData.sublistView(image).getUint32(4, Endian.little);
    if (boardMarker != de1BoardMarker) {
      return De1FirmwareImageClassification.unrecognizedAtLeastHeader;
    }

    final header = De1FirmwareHeader.parse(image);
    if (header.bodyByteCount <= 0 ||
        header.bodyByteCount > image.length - byteLength) {
      throw const FormatException('Firmware body length is out of bounds');
    }
    if (header.cpuByteCount <= 0 ||
        header.cpuByteCount > header.bodyByteCount) {
      throw const FormatException('Firmware CPU length is out of bounds');
    }
    if (header.unused != 0) {
      throw const FormatException('Firmware header reserved field is non-zero');
    }
    if (header.checksum == 0 ||
        header.decryptedChecksum == 0 ||
        header.headerChecksum == 0 ||
        header.initializationVector.every((byte) => byte == 0)) {
      throw const FormatException('Firmware header checksums are incomplete');
    }
    return De1FirmwareImageClassification.canonicalDe1;
  }
}
