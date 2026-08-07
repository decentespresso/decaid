/// Centralized policy values bounding backup transfer, archive, and record
/// processing. Everything here exists so peak memory and disk use scale with
/// batch/record size rather than backup size (issue #555).
///
/// Limits are intentionally below ZIP64 thresholds (4 GiB, 65535 entries) so
/// the writer never needs Zip64 and the reader can reject it outright.
class DataTransferLimits {
  /// Hard cap on a staged import request body (compressed ZIP bytes).
  final int maxImportRequestBytes;

  /// Cap on the sum of uncompressed section sizes written by one export or
  /// read from one import.
  final int maxTotalUncompressedBytes;

  /// Cap on one entry's uncompressed size, enforced while inflating.
  final int maxEntryUncompressedBytes;

  /// Cap on the number of entries a ZIP may contain.
  final int maxEntryCount;

  /// Cap on metadata.json size.
  final int maxMetadataBytes;

  /// Cap on one JSON value (record, KV value, singleton payload) at any stage.
  final int maxRecordBytes;

  /// Cap on one JSON object key.
  final int maxKeyBytes;

  /// Cap on one ZIP filename (bytes).
  final int maxFilenameBytes;

  /// Cap on one ZIP extra field / comment (bytes).
  final int maxExtraFieldBytes;

  /// Cap on one ZIP entry comment (bytes).
  final int maxCommentBytes;

  /// Cap on JSON nesting depth (parser and decode safety).
  final int maxNestingDepth;

  /// Cap on a sync request JSON body.
  final int maxSyncRequestBytes;

  /// Cap on a sync target's import response body.
  final int maxSyncResponseBytes;

  /// Cap on the native import JSON response body.
  final int maxImportResponseBytes;

  /// Timeout for establishing the TCP connection (applied as the HTTP
  /// client's `connectionTimeout`). Server-side export/import processing is
  /// NOT counted against it; phases are bounded by [syncOverallTimeout].
  final Duration syncHeaderTimeout;

  /// Timeout between consecutive response-stream events.
  final Duration syncIdleTimeout;

  /// Timeout for a complete pull or push phase.
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

  /// Largest offset/size representable without ZIP64.
  static const int maxZip32 = 0xFFFFFFFF;

  /// Smallest page used by streaming sections.
  static const int defaultExportPageSize = 200;
}
