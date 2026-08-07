class DataTransferLimits {
  final int maxImportRequestBytes;

  final int maxTotalUncompressedBytes;

  final int maxEntryUncompressedBytes;

  final int maxEntryCount;

  final int maxMetadataBytes;

  final int maxRecordBytes;

  final int maxKeyBytes;

  final int maxFilenameBytes;

  final int maxExtraFieldBytes;

  final int maxCommentBytes;

  final int maxNestingDepth;

  final int maxSyncRequestBytes;

  final int maxSyncResponseBytes;

  final int maxImportResponseBytes;

  final Duration syncHeaderTimeout;

  final Duration syncIdleTimeout;

  final Duration syncOverallTimeout;

  const DataTransferLimits({
    this.maxImportRequestBytes = 0x7FFFFFFF,
    this.maxTotalUncompressedBytes = 2 * 1024 * 1024 * 1024,
    this.maxEntryUncompressedBytes = 1024 * 1024 * 1024,
    this.maxEntryCount = 4096,
    this.maxMetadataBytes = 64 * 1024,
    this.maxRecordBytes = 64 * 1024 * 1024,
    this.maxKeyBytes = 64 * 1024,
    this.maxFilenameBytes = 256,
    this.maxExtraFieldBytes = 64 * 1024,
    this.maxCommentBytes = 64 * 1024,
    this.maxNestingDepth = 256,
    this.maxSyncRequestBytes = 1024 * 1024,
    this.maxSyncResponseBytes = 8 * 1024 * 1024,
    this.maxImportResponseBytes = 8 * 1024 * 1024,
    this.syncHeaderTimeout = const Duration(seconds: 10),
    this.syncIdleTimeout = const Duration(seconds: 30),
    this.syncOverallTimeout = const Duration(minutes: 10),
  });

  static const int maxZip32 = 0xFFFFFFFF;

  static const int defaultExportPageSize = 200;
}
