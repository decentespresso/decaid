import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;
import 'package:reaprime/src/util/remote_error.dart';
import 'package:reaprime/src/util/remote_update_exception.dart';
import 'package:reaprime/src/util/remote_update_report.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/services/github_request.dart';
import 'package:reaprime/src/services/release_request.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';
import 'package:reaprime/src/util/safe_path.dart';
import 'package:reaprime/src/webui_support/webui_zip_support.dart';

class WebUIReaMetadata {
  final String skinId;
  final String? sourceUrl;
  final String? lastModified;
  final String? etag;
  final String? commitHash;
  final String? releaseAssetName;
  final bool? includePrerelease;
  final DateTime installedAt;
  final DateTime? lastChecked;

  WebUIReaMetadata({
    required this.skinId,
    this.sourceUrl,
    this.lastModified,
    this.etag,
    this.commitHash,
    this.releaseAssetName,
    this.includePrerelease,
    required this.installedAt,
    this.lastChecked,
  });

  factory WebUIReaMetadata.fromJson(Map<String, dynamic> json) {
    return WebUIReaMetadata(
      skinId: json['skinId'] as String,
      sourceUrl: json['sourceUrl'] as String?,
      lastModified: json['lastModified'] as String?,
      etag: json['etag'] as String?,
      commitHash: json['commitHash'] as String?,
      releaseAssetName: json['releaseAssetName'] as String?,
      includePrerelease: json['includePrerelease'] as bool?,
      installedAt: DateTime.parse(json['installedAt'] as String),
      lastChecked: json['lastChecked'] != null
          ? DateTime.parse(json['lastChecked'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'skinId': skinId,
      'sourceUrl': sourceUrl,
      'lastModified': lastModified,
      'etag': etag,
      'commitHash': commitHash,
      'releaseAssetName': releaseAssetName,
      'includePrerelease': includePrerelease,
      'installedAt': installedAt.toIso8601String(),
      'lastChecked': lastChecked?.toIso8601String(),
    };
  }

  WebUIReaMetadata copyWith({
    String? sourceUrl,
    String? lastModified,
    String? etag,
    String? commitHash,
    String? releaseAssetName,
    bool? includePrerelease,
    DateTime? installedAt,
    DateTime? lastChecked,
  }) {
    return WebUIReaMetadata(
      skinId: skinId,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      lastModified: lastModified ?? this.lastModified,
      etag: etag ?? this.etag,
      commitHash: commitHash ?? this.commitHash,
      releaseAssetName: releaseAssetName ?? this.releaseAssetName,
      includePrerelease: includePrerelease ?? this.includePrerelease,
      installedAt: installedAt ?? this.installedAt,
      lastChecked: lastChecked ?? this.lastChecked,
    );
  }
}

class WebUISkin {
  final String id;
  final String name;
  final String path;
  final String? description;
  final String? version;
  final bool isBundled;
  final WebUIReaMetadata? reaMetadata;

  WebUISkin({
    required this.id,
    required this.name,
    required this.path,
    this.description,
    this.version,
    this.isBundled = false,
    this.reaMetadata,
  });

  factory WebUISkin.fromJson(Map<String, dynamic> json) {
    return WebUISkin(
      id: json['id'] as String,
      name: json['name'] as String,
      path: json['path'] as String,
      description: json['description'] as String?,
      version: json['version'] as String?,
      isBundled: json['isBundled'] as bool? ?? false,
      reaMetadata: json['reaMetadata'] != null
          ? WebUIReaMetadata.fromJson(
              json['reaMetadata'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'description': description,
      'version': version,
      'isBundled': isBundled,
      'reaMetadata': reaMetadata?.toJson(),
    };
  }
}

enum ManagedSkinLookupStatus {
  resolved,
  invalidId,
  missing,
  escaped,
  ambiguous,
  unreadable,
}

final class ManagedSkinLookup {
  const ManagedSkinLookup._(
    this.status, {
    this.skinId,
    this.directoryName,
    this.canonicalPath,
  });

  const ManagedSkinLookup.notManaged(ManagedSkinLookupStatus status)
    : this._(status);

  const ManagedSkinLookup.resolved({
    required String skinId,
    required String directoryName,
    required String canonicalPath,
  }) : this._(
         ManagedSkinLookupStatus.resolved,
         skinId: skinId,
         directoryName: directoryName,
         canonicalPath: canonicalPath,
       );

  final ManagedSkinLookupStatus status;
  final String? skinId;
  final String? directoryName;
  final String? canonicalPath;

  bool get isResolved => status == ManagedSkinLookupStatus.resolved;
}

enum CleanSkinSourceStatus {
  qualified,
  invalidSkinId,
  skinSelectionRejected,
  installedPackageUnsafe,
  installedPackageUnreadable,
  bundledManifestUnavailable,
  bundledSourceAbsent,
  bundledSourceAmbiguous,
  bundledSourceUnreadable,
  bundledSourceUnsafe,
  packageContentMismatch,
}

final class CleanSkinSourceQualification {
  const CleanSkinSourceQualification.qualified({
    required this.skinId,
    required this.bundledAssetKey,
  }) : status = CleanSkinSourceStatus.qualified,
       selectionStatus = null;

  const CleanSkinSourceQualification.rejected(
    this.status, {
    this.selectionStatus,
  }) : skinId = null,
       bundledAssetKey = null;

  final CleanSkinSourceStatus status;
  final String? skinId;
  final String? bundledAssetKey;
  final ManagedSkinLookupStatus? selectionStatus;

  bool get isQualified => status == CleanSkinSourceStatus.qualified;
}

final class _CleanSkinArchiveLayout {
  const _CleanSkinArchiveLayout({required this.headers, required this.sizes});

  final Map<String, ZipFileHeader> headers;
  final Map<String, int> sizes;
}

final class _CleanSkinBundledSource {
  const _CleanSkinBundledSource({
    required this.assetKey,
    required this.headers,
    required this.sizes,
  });

  final String assetKey;
  final Map<String, ZipFileHeader> headers;
  final Map<String, int> sizes;
}

final class _CleanSkinSourceScanResult {
  const _CleanSkinSourceScanResult(this.outcome, [this.source]);

  final _CleanSkinSourceScan outcome;
  final _CleanSkinBundledSource? source;
}

const int _maxSkinManifestBytes = 256 * 1024;

const int _maxBundledSkinSourceCount = 64;
const int _maxBundledSkinArchiveBytes = 32 * 1024 * 1024;
const int _maxCleanSkinSourcesBytes = 128 * 1024 * 1024;
const int _maxCleanSkinEntries = 4096;
const int _maxCleanSkinFileBytes = 16 * 1024 * 1024;
const int _maxCleanSkinPackageBytes = 64 * 1024 * 1024;
const int _maxCleanSkinPackageCompressedBytes = 64 * 1024 * 1024;
const int _maxCleanSkinParseBytes = 4 * 32 * 1024 * 1024;
const int _maxCleanSkinPathDepth = 32;
const int _maxCleanSkinPathLength = 1024;
const String _bundledSkinManifestAssetKey =
    'assets/bundled_skins/manifest.json';
const String _bundledSkinAssetPrefix = 'assets/bundled_skins/';

const Set<String> _win32ReservedNames = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

final class _CleanSkinRejected implements Exception {
  const _CleanSkinRejected();
}

enum _CleanSkinEntryKind { file, directory, link, other }

enum _CleanSkinSourceScan { match, other, unsafe, unreadable }

final class _CleanSkinPathIndex {
  final _spellingByFoldedPath = <String, String>{};
  final _kindByFoldedPath = <String, _CleanSkinEntryKind>{};

  bool add(String path, _CleanSkinEntryKind kind) {
    final components = path.split('/');
    for (var depth = 1; depth <= components.length; depth++) {
      final prefix = components.take(depth).join('/');
      final folded = prefix.toLowerCase();
      final spelling = _spellingByFoldedPath[folded];
      if (spelling == null) {
        _spellingByFoldedPath[folded] = prefix;
        _kindByFoldedPath[folded] = depth == components.length
            ? kind
            : _CleanSkinEntryKind.directory;
        continue;
      }
      if (spelling != prefix || depth == components.length) return false;
      if (_kindByFoldedPath[folded] != _CleanSkinEntryKind.directory) {
        return false;
      }
    }
    return true;
  }
}

final class _BoundedCleanSkinInput extends InputMemoryStream {
  _BoundedCleanSkinInput(super.bytes);

  int _consumed = 0;

  void _consume(int count) {
    if (count > _maxCleanSkinParseBytes - _consumed) {
      throw const _CleanSkinRejected();
    }
    _consumed += count;
    _recordCleanSkinParseReads(_consumed);
  }

  @override
  int readByte() {
    _consume(1);
    return super.readByte();
  }

  @override
  InputStream readBytes(int count) {
    final available = length;
    _consume(count > available ? available : count);
    return super.readBytes(count);
  }
}

final class _BoundedCleanSkinSink implements Sink<List<int>> {
  _BoundedCleanSkinSink(this.maxBytes);

  final int maxBytes;
  final _bytes = BytesBuilder(copy: false);

  int get length => _bytes.length;

  @override
  void add(List<int> chunk) {
    final room = maxBytes - _bytes.length;
    if (chunk.length > room) {
      if (room > 0) _bytes.add(chunk.sublist(0, room));
      throw const _CleanSkinRejected();
    }
    _bytes.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}

bool _isCleanSkinRelativePath(String path) {
  if (path.isEmpty || path.length > _maxCleanSkinPathLength) return false;
  final components = path.split('/');
  if (components.length > _maxCleanSkinPathDepth) return false;
  return components.every(_isCleanSkinPathComponent);
}

bool _isCleanSkinPathComponent(String component) {
  if (component.isEmpty || component == '.' || component == '..') return false;
  for (final unit in component.codeUnits) {
    if (unit < 0x20 || unit > 0x7e) return false;
  }
  if (!isSafePathComponent(component)) return false;
  return !_win32ReservedNames.contains(
    component.split('.').first.toUpperCase(),
  );
}

String _stripCleanSkinTrailingSlashes(String name) {
  var stripped = name;
  while (stripped.isNotEmpty &&
      (stripped.endsWith('/') || stripped.endsWith('\\'))) {
    stripped = stripped.substring(0, stripped.length - 1);
  }
  return stripped;
}

_CleanSkinEntryKind _cleanSkinArchiveEntryKind(ZipFileHeader header) {
  if (header.versionMadeBy >> 8 == 3) {
    final fileType = (header.externalFileAttributes >> 16) & 0xf000;
    if (fileType == 0x4000) return _CleanSkinEntryKind.directory;
    if (fileType == 0x8000 || fileType == 0x0000) {
      return _CleanSkinEntryKind.file;
    }
    if (fileType == 0xa000) return _CleanSkinEntryKind.link;
    return _CleanSkinEntryKind.other;
  }
  final name = header.filename;
  return name.endsWith('/') || name.endsWith('\\')
      ? _CleanSkinEntryKind.directory
      : _CleanSkinEntryKind.file;
}

Uint8List _readCleanSkinArchiveContent(ZipFileHeader header) {
  final file = header.file;
  if (file == null) throw const _CleanSkinRejected();
  final sink = _BoundedCleanSkinSink(header.uncompressedSize);
  try {
    if (file.compressionMethod == CompressionType.none) {
      sink.add(file.getRawContent());
    } else if (file.compressionMethod == CompressionType.deflate) {
      final decoder = ZLibCodec(gzip: true).decoder
          .startChunkedConversion(sink);
      decoder.add(_cleanSkinGzipFrame(file.getRawContent(), header));
      decoder.close();
    } else {
      throw const _CleanSkinRejected();
    }
    if (sink.length != header.uncompressedSize) {
      throw const _CleanSkinRejected();
    }
    final bytes = sink.takeBytes();
    _recordCleanSkinInflation(bytes.length);
    if (getCrc32(bytes) != header.crc32) throw const _CleanSkinRejected();
    return bytes;
  } on _CleanSkinRejected {
    _recordCleanSkinInflation(sink.length);
    rethrow;
  } catch (_) {
    _recordCleanSkinInflation(sink.length);
    throw const _CleanSkinRejected();
  }
}

Uint8List _cleanSkinGzipFrame(Uint8List compressed, ZipFileHeader header) {
  final crc = header.crc32;
  final size = header.uncompressedSize;
  final frame = BytesBuilder(copy: false)
    ..add(const [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
    ..add(compressed)
    ..add([
      crc & 0xff,
      (crc >> 8) & 0xff,
      (crc >> 16) & 0xff,
      (crc >> 24) & 0xff,
      size & 0xff,
      (size >> 8) & 0xff,
      (size >> 16) & 0xff,
      (size >> 24) & 0xff,
    ]);
  return frame.takeBytes();
}

int _cleanSkinCompressionCode(CompressionType type) => switch (type) {
  CompressionType.none => ZipFile.zipCompressionStore,
  CompressionType.deflate => ZipFile.zipCompressionDeflate,
  CompressionType.bzip2 => ZipFile.zipCompressionBZip2,
};

int _cleanSkinUint16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

int _cleanSkinUint32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

const int _zip64LocatorSize = 20;
const int _zip64LocatorSignature = 0x07064b50;
const int _cleanSkinZip64Sentinel = 0xffffffff;
const int _cleanSkinZip64ExtraFieldId = 0x0001;

bool _hasCleanSkinZip64ExtraField(Uint8List bytes, int start, int length) {
  var cursor = start;
  final end = start + length;
  while (cursor + 4 <= end) {
    final id = _cleanSkinUint16(bytes, cursor);
    final size = _cleanSkinUint16(bytes, cursor + 2);
    if (id == _cleanSkinZip64ExtraFieldId) return true;
    cursor += 4 + size;
  }
  return false;
}

bool _isZip64LocatorBefore(Uint8List bytes, int eocdOffset) {
  final locatorOffset = eocdOffset - _zip64LocatorSize;
  if (locatorOffset < 0) return false;
  return _cleanSkinUint32(bytes, locatorOffset) == _zip64LocatorSignature;
}

bool _hasEarlierCleanSkinEndOfCentralDirectory(
  Uint8List bytes,
  int eocdOffset,
) {
  for (var offset = 0; offset + 4 <= eocdOffset; offset++) {
    if (_cleanSkinUint32(bytes, offset) == 0x06054b50) return true;
  }
  return false;
}

bool _hasBoundedCleanSkinCentralDirectory(Uint8List bytes) {
  const endSize = 22;
  if (bytes.length < endSize) return false;
  for (var offset = bytes.length - endSize; offset >= 0; offset--) {
    if (bytes[offset] != 0x50 ||
        bytes[offset + 1] != 0x4b ||
        bytes[offset + 2] != 0x05 ||
        bytes[offset + 3] != 0x06) {
      continue;
    }
    if (offset + endSize + _cleanSkinUint16(bytes, offset + 20) !=
        bytes.length) {
      return false;
    }
    if (_hasEarlierCleanSkinEndOfCentralDirectory(bytes, offset)) return false;
    if (_isZip64LocatorBefore(bytes, offset)) return false;
    final entries = _cleanSkinUint16(bytes, offset + 10);
    final size = _cleanSkinUint32(bytes, offset + 12);
    final directoryOffset = _cleanSkinUint32(bytes, offset + 16);
    if (entries == 0 || entries > _maxCleanSkinEntries) return false;
    if (directoryOffset + size > bytes.length) return false;
    var cursor = directoryOffset;
    final end = directoryOffset + size;
    for (var index = 0; index < entries; index++) {
      if (cursor + 46 > end) return false;
      if (bytes[cursor] != 0x50 ||
          bytes[cursor + 1] != 0x4b ||
          bytes[cursor + 2] != 0x01 ||
          bytes[cursor + 3] != 0x02) {
        return false;
      }
      final nameLength = _cleanSkinUint16(bytes, cursor + 28);
      final extraLength = _cleanSkinUint16(bytes, cursor + 30);
      final commentLength = _cleanSkinUint16(bytes, cursor + 32);
      if (_cleanSkinUint32(bytes, cursor + 20) == _cleanSkinZip64Sentinel ||
          _cleanSkinUint32(bytes, cursor + 24) == _cleanSkinZip64Sentinel ||
          _cleanSkinUint32(bytes, cursor + 42) == _cleanSkinZip64Sentinel) {
        return false;
      }
      final extraStart = cursor + 46 + nameLength;
      if (extraStart + extraLength > end) return false;
      if (_hasCleanSkinZip64ExtraField(bytes, extraStart, extraLength)) {
        return false;
      }
      cursor = extraStart + extraLength + commentLength;
      if (cursor > end) return false;
    }
    return cursor == end;
  }
  return false;
}

void _recordCleanSkinInflation(int bytes) {
  if (bytes > (WebUIStorage.debugCleanSkinInflationBytesWritten ?? 0)) {
    WebUIStorage.debugCleanSkinInflationBytesWritten = bytes;
  }
}

void _recordCleanSkinParseReads(int bytes) {
  if (bytes > (WebUIStorage.debugCleanSkinParseBytesRead ?? 0)) {
    WebUIStorage.debugCleanSkinParseBytesRead = bytes;
  }
}

final class _ManagedSkinPackage {
  const _ManagedSkinPackage({
    required this.skinId,
    required this.directoryName,
    required this.name,
    required this.path,
    required this.canonicalPath,
    this.description,
    this.version,
  });

  final String skinId;
  final String directoryName;
  final String name;
  final String path;
  final String canonicalPath;
  final String? description;
  final String? version;
}

final class _ManagedSkinInspection {
  const _ManagedSkinInspection.package(_ManagedSkinPackage this.package)
    : status = ManagedSkinLookupStatus.resolved;

  const _ManagedSkinInspection.skipped(this.status) : package = null;

  final ManagedSkinLookupStatus status;
  final _ManagedSkinPackage? package;
}

final class _ManagedSkinSnapshot {
  const _ManagedSkinSnapshot({required this.packages, required this.skipped});

  final Map<String, List<_ManagedSkinPackage>> packages;
  final Map<String, ManagedSkinLookupStatus> skipped;
}

/// Narrow read-only filesystem seam for [WebUIStorage.resolveManagedSelectedSkin].
abstract class ManagedSkinFileAccess {
  /// Names of the subdirectories of [path], including links that resolve to a
  /// directory.
  Future<List<String>> listSubdirectoryNames(String path);

  /// Type of [path]; [followLinks] is false by default so a symbolic link is
  /// reported as a link instead of being traversed.
  Future<FileSystemEntityType> entityType(
    String path, {
    bool followLinks = false,
  });

  /// Textual target of the symbolic link at [path], without traversing it.
  Future<String> linkTarget(String path);

  /// Canonical path of [path], traversing any symbolic links.
  Future<String> canonicalPath(String path);

  /// Text of the file at [path]; a file longer than [maxBytes] throws
  /// [FormatException].
  Future<String> readBoundedText(String path, {required int maxBytes});

  /// Reads one byte of the file at [path] to prove that it is readable.
  Future<void> probeReadableFile(String path);
}

final class SystemManagedSkinFileAccess implements ManagedSkinFileAccess {
  const SystemManagedSkinFileAccess();

  @override
  Future<List<String>> listSubdirectoryNames(String path) async => [
    for (final entity in Directory(path).listSync(followLinks: false))
      if (entity is Directory || entity is Link) p.basename(entity.path),
  ];

  @override
  Future<FileSystemEntityType> entityType(
    String path, {
    bool followLinks = false,
  }) => FileSystemEntity.type(path, followLinks: followLinks);

  @override
  Future<String> linkTarget(String path) async => Link(path).targetSync();

  @override
  Future<String> canonicalPath(String path) async {
    if (await FileSystemEntity.type(path, followLinks: true) ==
        FileSystemEntityType.directory) {
      return Directory(path).resolveSymbolicLinks();
    }
    return File(path).resolveSymbolicLinks();
  }

  @override
  Future<String> readBoundedText(String path, {required int maxBytes}) async {
    final chunks = await File(path).openRead(0, maxBytes + 1).toList();
    final bytes = <int>[for (final chunk in chunks) ...chunk];
    if (bytes.length > maxBytes) {
      throw FormatException('File exceeds $maxBytes bytes', path);
    }
    return utf8.decode(bytes);
  }

  @override
  Future<void> probeReadableFile(String path) async {
    await File(path).openRead(0, 1).toList();
  }
}

class WebUIStorage {
  final _log = Logger('WebUIStorage');
  static const _stagingDirName = '.webui-install-staging';
  static const _skinManifestNames = ['skin-manifest.json', 'manifest.json'];
  final SettingsController _settingsController;
  final Directory? _webUIDirOverride;
  final ManagedSkinFileAccess _skinFileAccess;
  final AssetBundle _bundledSkinAssets;

  late Directory _webUIDir;
  final Map<String, WebUISkin> _installedSkins = {};
  final Map<String, List<String>> _skinPaths = {};
  final Map<String, WebUIReaMetadata> _skinMetadata = {};
  bool _initialized = false;
  final ValueNotifier<Future<void>?> _updateCheck = ValueNotifier(null);
  Future<RemoteUpdateReport>? _updateCheckReport;
  Future<List<RemoteUpdateItemResult>>? _remoteDownload;
  Future<void>? _downloadRemoteSkinsCheck;

  final GithubRateLimit _rateLimit;
  final GithubCredentialProvider? credentials;

  WebUIStorage(
    this._settingsController, {
    Directory? webUIDir,
    GithubRateLimit? rateLimit,
    this.credentials,
    ManagedSkinFileAccess? skinFileAccess,
    AssetBundle? bundledSkinAssets,
  }) : _webUIDirOverride = webUIDir,
       _rateLimit = rateLimit ?? GithubRateLimit(),
       _skinFileAccess = skinFileAccess ?? const SystemManagedSkinFileAccess(),
       _bundledSkinAssets = bundledSkinAssets ?? rootBundle;

  Future<http.Response> _getGitHubRelease(String apiUrl) =>
      githubGet(apiUrl, rateLimit: _rateLimit, credentials: credentials);

  ValueListenable<Future<void>?> get updateCheck => _updateCheck;

  @visibleForTesting
  static bool get diagnosticsSkinEnabled => bool.fromEnvironment('diagnostics');

  @visibleForTesting
  static int? debugCleanSkinInflationBytesWritten;

  @visibleForTesting
  static int? debugCleanSkinParseBytesRead;

  @visibleForTesting
  void debugInitWithWebUIDir(Directory dir) {
    _webUIDir = dir;
    if (!_webUIDir.existsSync()) {
      _webUIDir.createSync(recursive: true);
    }
    _initialized = true;
  }

  static List<String> get _bundledAssetPaths =>
      diagnosticsSkinEnabled ? ['assets/ble-reconnect-diagnostics/'] : [];

  static List<Map<String, dynamic>>? _remoteWebUISourcesCache;

  Future<List<Map<String, dynamic>>> _getRemoteWebUISources() async {
    if (_remoteWebUISourcesCache != null) return _remoteWebUISourcesCache!;
    try {
      final configString = await rootBundle.loadString('skin_sources.json');
      _remoteWebUISourcesCache = (jsonDecode(configString) as List)
          .cast<Map<String, dynamic>>();
    } catch (e) {
      _log.warning('Failed to load skin_sources.json', e);
      _remoteWebUISourcesCache = [];
    }
    return _remoteWebUISourcesCache!;
  }

  final Set<String> _remoteBundledSkinIds = {};

  Future<void> initialize({bool downloadRemote = true}) async {
    if (_initialized) {
      _log.fine('WebUIStorage already initialized');
      return;
    }

    _webUIDir = _webUIDirOverride ?? Directory(await AppDirectories.webUi);

    if (!_webUIDir.existsSync()) {
      _webUIDir.createSync(recursive: true);
      _log.info('Created web-ui directory: ${_webUIDir.path}');
    }

    await _loadRemoteBundledSkinIds();

    await _loadSkinMetadata();

    await _copyBundledSkins();

    if (downloadRemote) {
      try {
        await downloadRemoteSkins();
      } on RemoteUpdateException catch (e, st) {
        _log.warning('Remote skins unavailable during initialization', e, st);
      }
    }

    await _scanInstalledSkins();

    _initialized = true;
    _log.info('WebUIStorage initialized with ${_installedSkins.length} skins');
  }

  List<WebUISkin> get installedSkins => _installedSkins.values.toList();

  WebUISkin? getSkin(String id) => _installedSkins[id];

  Iterable<String> legacySkinPaths(String path) {
    final skin = _installedSkins.values
        .where((skin) => skin.path == path)
        .firstOrNull;
    if (skin == null) return const [];
    return (_skinPaths[skin.id] ?? const <String>[]).reversed.where(
      (candidate) => candidate != path,
    );
  }

  WebUISkin? get defaultSkin {
    final preferredSkinId = _settingsController.defaultSkinId;
    _log.info(
      "selecting preferred skin: $preferredSkinId, in: $_installedSkins",
    );
    if (_installedSkins.containsKey(preferredSkinId)) {
      return _installedSkins[preferredSkinId];
    }

    if (preferredSkinId != 'streamline.js') {
      _log.warning(
        'Preferred skin "$preferredSkinId" not found, falling back to default',
      );
    }

    final streamlineSkin = _installedSkins['streamline.js'];
    if (streamlineSkin != null) {
      return streamlineSkin;
    }

    final bundledSkin = _installedSkins.values
        .where((skin) => skin.isBundled)
        .firstOrNull;

    if (bundledSkin != null) {
      return bundledSkin;
    }

    return _installedSkins.values.firstOrNull;
  }

  Future<void> setDefaultSkin(String skinId) async {
    if (!_installedSkins.containsKey(skinId)) {
      throw Exception('Skin not found: $skinId');
    }

    await _settingsController.setDefaultSkinId(skinId);
    _log.info('Set default skin to: $skinId');
  }

  Future<ManagedSkinLookup> resolveManagedSelectedSkin(
    String skinId, {
    String? runtimePath,
    bool followLinks = true,
  }) async {
    if (!isSafePathComponent(skinId) || skinId == _stagingDirName) {
      return const ManagedSkinLookup.notManaged(
        ManagedSkinLookupStatus.invalidId,
      );
    }

    final root = _webUIDirOverride ?? (_initialized ? _webUIDir : null);
    if (root == null) {
      return const ManagedSkinLookup.notManaged(
        ManagedSkinLookupStatus.unreadable,
      );
    }

    final rootPath = p.normalize(root.path);
    String? runtimeDirectoryName;
    if (runtimePath != null) {
      final normalizedRuntimePath = p.normalize(p.absolute(runtimePath));
      final runtimeName = p.basename(normalizedRuntimePath);
      if (p.dirname(normalizedRuntimePath) != rootPath ||
          runtimeName == _stagingDirName ||
          !isSafePathComponent(runtimeName)) {
        _log.warning(
          'Runtime skin selection is not a managed package directory',
        );
        return const ManagedSkinLookup.notManaged(
          ManagedSkinLookupStatus.escaped,
        );
      }
      runtimeDirectoryName = runtimeName;
    }

    try {
      if (await _skinFileAccess.entityType(rootPath) ==
          FileSystemEntityType.notFound) {
        return const ManagedSkinLookup.notManaged(
          ManagedSkinLookupStatus.missing,
        );
      }
      final String canonicalRoot;
      try {
        canonicalRoot = await _skinFileAccess.canonicalPath(rootPath);
      } on FileSystemException {
        return const ManagedSkinLookup.notManaged(
          ManagedSkinLookupStatus.unreadable,
        );
      }
      if (await _skinFileAccess.entityType(canonicalRoot) !=
          FileSystemEntityType.directory) {
        return const ManagedSkinLookup.notManaged(
          ManagedSkinLookupStatus.missing,
        );
      }
      final snapshot = await _readManagedSkinSelectionSnapshot(
        rootPath,
        canonicalRoot,
        followLinks: followLinks,
      );
      final canonicalFailure = snapshot.skipped[skinId];
      if (canonicalFailure != null) {
        return ManagedSkinLookup.notManaged(canonicalFailure);
      }
      final candidates = snapshot.packages[skinId];
      if (candidates == null || candidates.isEmpty) {
        return ManagedSkinLookup.notManaged(
          snapshot.skipped[skinId] ?? ManagedSkinLookupStatus.missing,
        );
      }
      final selected = _selectCanonicalPackage(candidates);
      if (selected == null) {
        _log.warning('Skin "$skinId" matches competing managed packages');
        return const ManagedSkinLookup.notManaged(
          ManagedSkinLookupStatus.ambiguous,
        );
      }
      if (selected.directoryName != skinId && snapshot.skipped.isNotEmpty) {
        return const ManagedSkinLookup.notManaged(
          ManagedSkinLookupStatus.ambiguous,
        );
      }
      if (runtimeDirectoryName != null) {
        if (runtimeDirectoryName != selected.directoryName) {
          _log.warning(
            'Runtime skin path does not name the selected managed package',
          );
          return const ManagedSkinLookup.notManaged(
            ManagedSkinLookupStatus.ambiguous,
          );
        }
        final runtimeCanonicalPath = await _skinFileAccess.canonicalPath(
          p.join(rootPath, runtimeDirectoryName),
        );
        if (runtimeCanonicalPath != selected.canonicalPath) {
          _log.warning(
            'Runtime skin path escapes the selected managed package',
          );
          return const ManagedSkinLookup.notManaged(
            ManagedSkinLookupStatus.escaped,
          );
        }
      }
      final entryPointStatus = await _entryPointStatus(
        selected.canonicalPath,
        selected.path,
        followLinks: followLinks,
      );
      if (entryPointStatus != null) {
        return ManagedSkinLookup.notManaged(entryPointStatus);
      }
      return ManagedSkinLookup.resolved(
        skinId: selected.skinId,
        directoryName: selected.directoryName,
        canonicalPath: selected.canonicalPath,
      );
    } on FileSystemException catch (e, st) {
      _log.warning('Failed to read managed skin "$skinId"', e, st);
      return const ManagedSkinLookup.notManaged(
        ManagedSkinLookupStatus.unreadable,
      );
    } on FormatException catch (e, st) {
      _log.warning('Failed to decode managed skin "$skinId"', e, st);
      return const ManagedSkinLookup.notManaged(
        ManagedSkinLookupStatus.unreadable,
      );
    }
  }

  Future<_ManagedSkinSnapshot> _readManagedSkinSelectionSnapshot(
    String rootPath,
    String canonicalRoot, {
    required bool followLinks,
  }) async {
    final packages = <String, List<_ManagedSkinPackage>>{};
    final skipped = <String, ManagedSkinLookupStatus>{};
    for (final directoryName in await _skinFileAccess.listSubdirectoryNames(
      rootPath,
    )) {
      if (directoryName == _stagingDirName) continue;
      final directoryPath = p.join(rootPath, directoryName);
      final inspection = await _inspectManagedSkinSelectionPackage(
        directoryPath,
        rootPath,
        canonicalRoot,
        followLinks: followLinks,
      );
      final package = inspection.package;
      if (package == null) {
        skipped[directoryName] = inspection.status;
        _log.fine(
          'Skipping skin package at $directoryPath: ${inspection.status.name}',
        );
        continue;
      }
      (packages[package.skinId] ??= <_ManagedSkinPackage>[]).add(package);
    }
    return _ManagedSkinSnapshot(packages: packages, skipped: skipped);
  }

  Future<_ManagedSkinInspection> _inspectManagedSkinSelectionPackage(
    String directoryPath,
    String rootPath,
    String canonicalRoot, {
    required bool followLinks,
  }) async {
    final String canonicalPath;
    try {
      final rawType = await _skinFileAccess.entityType(directoryPath);
      if (rawType == FileSystemEntityType.notFound) {
        return const _ManagedSkinInspection.skipped(
          ManagedSkinLookupStatus.missing,
        );
      }
      if (rawType == FileSystemEntityType.directory) {
        canonicalPath = await _skinFileAccess.canonicalPath(directoryPath);
      } else if (rawType == FileSystemEntityType.link) {
        if (!followLinks) {
          return const _ManagedSkinInspection.skipped(
            ManagedSkinLookupStatus.escaped,
          );
        }
        if (!await _linkTargetsWithin(directoryPath, [
          rootPath,
          canonicalRoot,
        ])) {
          return const _ManagedSkinInspection.skipped(
            ManagedSkinLookupStatus.escaped,
          );
        }
        canonicalPath = await _skinFileAccess.canonicalPath(directoryPath);
      } else {
        return const _ManagedSkinInspection.skipped(
          ManagedSkinLookupStatus.unreadable,
        );
      }
    } on FileSystemException {
      return const _ManagedSkinInspection.skipped(
        ManagedSkinLookupStatus.unreadable,
      );
    }
    if (p.dirname(canonicalPath) != canonicalRoot ||
        p.basename(canonicalPath) == _stagingDirName) {
      return const _ManagedSkinInspection.skipped(
        ManagedSkinLookupStatus.escaped,
      );
    }

    final Map<String, dynamic>? manifest;
    try {
      manifest = await _readSelectionSkinManifest(
        canonicalPath,
        directoryPath,
        followLinks: followLinks,
      );
    } on FileSystemException {
      return const _ManagedSkinInspection.skipped(
        ManagedSkinLookupStatus.unreadable,
      );
    } on FormatException {
      return const _ManagedSkinInspection.skipped(
        ManagedSkinLookupStatus.unreadable,
      );
    }

    final directoryName = p.basename(canonicalPath);
    final declaredId = manifest?['id'];
    final declaredName = manifest?['name'];
    final description = manifest?['description'];
    final version = manifest?['version'];
    if ((declaredId != null && declaredId is! String) ||
        (declaredName != null && declaredName is! String) ||
        (description != null && description is! String) ||
        (version != null && version is! String)) {
      return const _ManagedSkinInspection.skipped(
        ManagedSkinLookupStatus.unreadable,
      );
    }
    final skinId = (declaredId as String?) ?? directoryName;
    if (!isSafePathComponent(skinId) || skinId == _stagingDirName) {
      return const _ManagedSkinInspection.skipped(
        ManagedSkinLookupStatus.invalidId,
      );
    }
    return _ManagedSkinInspection.package(
      _ManagedSkinPackage(
        skinId: skinId,
        directoryName: directoryName,
        name: (declaredName as String?) ?? directoryName,
        path: directoryPath,
        canonicalPath: canonicalPath,
        description: description as String?,
        version: version as String?,
      ),
    );
  }

  Future<bool> _linkTargetsWithin(
    String linkPath,
    List<String> containmentRoots,
  ) async {
    var pending = p.normalize(linkPath);
    final visited = <String>{};
    try {
      for (var depth = 0; depth < 32; depth++) {
        final root = containmentRoots
            .where((root) => p.isWithin(root, pending))
            .firstOrNull;
        if (root == null) return false;
        final components = p.split(p.relative(pending, from: root));
        var prefix = root;
        var redirected = false;
        for (var index = 0; index < components.length; index++) {
          prefix = p.join(prefix, components[index]);
          final type = await _skinFileAccess.entityType(prefix);
          if (type == FileSystemEntityType.link) {
            if (!visited.add(prefix)) return false;
            final target = await _skinFileAccess.linkTarget(prefix);
            final resolved = p.normalize(
              p.isAbsolute(target) ? target : p.join(p.dirname(prefix), target),
            );
            if (!containmentRoots.any((root) => p.isWithin(root, resolved))) {
              return false;
            }
            pending = p.joinAll([resolved, ...components.skip(index + 1)]);
            redirected = true;
            break;
          }
          if (index < components.length - 1 &&
              type != FileSystemEntityType.directory) {
            return false;
          }
          if (type == FileSystemEntityType.notFound) return false;
        }
        if (!redirected) return true;
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }

  Future<Map<String, dynamic>?> _readSelectionSkinManifest(
    String canonicalPackagePath,
    String logicalPackagePath, {
    required bool followLinks,
  }) async {
    for (final name in _skinManifestNames) {
      final manifestPath = p.join(canonicalPackagePath, name);
      final rawType = await _skinFileAccess.entityType(manifestPath);
      if (rawType == FileSystemEntityType.notFound) continue;
      final String resolvedPath;
      if (rawType == FileSystemEntityType.file) {
        resolvedPath = manifestPath;
      } else if (rawType == FileSystemEntityType.link) {
        if (!followLinks) {
          throw FileSystemException(
            'Skin manifest is a symbolic link',
            manifestPath,
          );
        }
        if (!await _linkTargetsWithin(manifestPath, [
          canonicalPackagePath,
          logicalPackagePath,
        ])) {
          throw FileSystemException(
            'Skin manifest resolves outside the package',
            manifestPath,
          );
        }
        resolvedPath = await _skinFileAccess.canonicalPath(manifestPath);
      } else {
        throw FileSystemException(
          'Skin manifest is not a regular file',
          manifestPath,
        );
      }
      if (!p.isWithin(canonicalPackagePath, resolvedPath) ||
          await _skinFileAccess.entityType(resolvedPath) !=
              FileSystemEntityType.file) {
        throw FileSystemException(
          'Skin manifest resolves outside the package',
          manifestPath,
        );
      }
      final decoded = jsonDecode(
        await _skinFileAccess.readBoundedText(
          resolvedPath,
          maxBytes: _maxSkinManifestBytes,
        ),
      );
      if (decoded is! Map) {
        throw const FormatException('Skin manifest is not a JSON object');
      }
      return Map<String, dynamic>.from(decoded);
    }
    return null;
  }

  Future<ManagedSkinLookupStatus?> _entryPointStatus(
    String canonicalPackagePath,
    String logicalPackagePath, {
    required bool followLinks,
  }) async {
    final entryPointPath = p.join(canonicalPackagePath, 'index.html');
    final rawType = await _skinFileAccess.entityType(entryPointPath);
    if (rawType == FileSystemEntityType.notFound ||
        rawType == FileSystemEntityType.directory) {
      return ManagedSkinLookupStatus.missing;
    }
    final String resolvedPath;
    try {
      if (rawType == FileSystemEntityType.file) {
        resolvedPath = entryPointPath;
      } else if (rawType == FileSystemEntityType.link) {
        if (!followLinks) return ManagedSkinLookupStatus.unreadable;
        if (!await _linkTargetsWithin(entryPointPath, [
          canonicalPackagePath,
          logicalPackagePath,
        ])) {
          return ManagedSkinLookupStatus.unreadable;
        }
        resolvedPath = await _skinFileAccess.canonicalPath(entryPointPath);
      } else {
        return ManagedSkinLookupStatus.unreadable;
      }
      if (!p.isWithin(canonicalPackagePath, resolvedPath)) {
        return ManagedSkinLookupStatus.unreadable;
      }
      if (await _skinFileAccess.entityType(resolvedPath) !=
          FileSystemEntityType.file) {
        return ManagedSkinLookupStatus.missing;
      }
      await _skinFileAccess.probeReadableFile(resolvedPath);
    } on FileSystemException {
      return ManagedSkinLookupStatus.unreadable;
    }
    return null;
  }

  _ManagedSkinPackage? _selectCanonicalPackage(
    List<_ManagedSkinPackage> packages,
  ) {
    for (final package in packages) {
      if (package.directoryName == package.skinId) return package;
    }
    return packages.length == 1 ? packages.single : null;
  }

  Future<CleanSkinSourceQualification> qualifyCleanBundledSkinSource(
    String skinId, {
    String? runtimePath,
  }) async {
    debugCleanSkinInflationBytesWritten = null;
    debugCleanSkinParseBytesRead = null;
    if (!isSafePathComponent(skinId) || skinId == _stagingDirName) {
      return const CleanSkinSourceQualification.rejected(
        CleanSkinSourceStatus.invalidSkinId,
      );
    }
    final selection = await resolveManagedSelectedSkin(
      skinId,
      runtimePath: runtimePath,
      followLinks: false,
    );
    final packagePath = selection.canonicalPath;
    if (!selection.isResolved || packagePath == null) {
      return CleanSkinSourceQualification.rejected(
        CleanSkinSourceStatus.skinSelectionRejected,
        selectionStatus: selection.status,
      );
    }

    final Map<String, int> installedSizes;
    try {
      installedSizes = await _readCleanSkinInstalledLayout(packagePath);
    } on _CleanSkinRejected {
      return const CleanSkinSourceQualification.rejected(
        CleanSkinSourceStatus.installedPackageUnsafe,
      );
    } on FileSystemException {
      return const CleanSkinSourceQualification.rejected(
        CleanSkinSourceStatus.installedPackageUnreadable,
      );
    }

    final sourceIds = await _readBundledSkinSourceIds();
    if (sourceIds == null) {
      return const CleanSkinSourceQualification.rejected(
        CleanSkinSourceStatus.bundledManifestUnavailable,
      );
    }

    var sawUnsafe = false;
    var sawUnreadable = false;
    var inspectedBytes = 0;
    _CleanSkinBundledSource? match;
    for (final sourceId in sourceIds) {
      final assetKey = '$_bundledSkinAssetPrefix$sourceId.zip';
      final bytes = await _loadBundledSkinAsset(assetKey);
      if (bytes == null) {
        sawUnreadable = true;
        continue;
      }
      inspectedBytes += bytes.length;
      if (inspectedBytes > _maxCleanSkinSourcesBytes) {
        sawUnsafe = true;
        break;
      }
      if (bytes.length > _maxBundledSkinArchiveBytes) {
        sawUnsafe = true;
        continue;
      }
      final scan = _scanBundledSkinSource(assetKey, bytes, skinId);
      switch (scan.outcome) {
        case _CleanSkinSourceScan.unsafe:
          sawUnsafe = true;
        case _CleanSkinSourceScan.unreadable:
          sawUnreadable = true;
        case _CleanSkinSourceScan.other:
          break;
        case _CleanSkinSourceScan.match:
          if (match != null) {
            return const CleanSkinSourceQualification.rejected(
              CleanSkinSourceStatus.bundledSourceAmbiguous,
            );
          }
          match = scan.source;
      }
    }

    final matched = match;
    if (matched == null) {
      return CleanSkinSourceQualification.rejected(
        sawUnsafe
            ? CleanSkinSourceStatus.bundledSourceUnsafe
            : sawUnreadable
            ? CleanSkinSourceStatus.bundledSourceUnreadable
            : CleanSkinSourceStatus.bundledSourceAbsent,
      );
    }
    if (sawUnsafe) {
      return const CleanSkinSourceQualification.rejected(
        CleanSkinSourceStatus.bundledSourceUnsafe,
      );
    }
    if (sawUnreadable) {
      return const CleanSkinSourceQualification.rejected(
        CleanSkinSourceStatus.bundledSourceUnreadable,
      );
    }

    final mismatch = await _compareCleanSkinPackageContent(
      packagePath,
      installedSizes,
      matched,
    );
    if (mismatch != null) {
      return CleanSkinSourceQualification.rejected(mismatch);
    }
    return CleanSkinSourceQualification.qualified(
      skinId: selection.skinId ?? skinId,
      bundledAssetKey: matched.assetKey,
    );
  }

  Future<Map<String, int>> _readCleanSkinInstalledLayout(
    String rootPath,
  ) async {
    final sizes = <String, int>{};
    final index = _CleanSkinPathIndex();
    var entries = 0;
    var totalBytes = 0;

    Future<void> walk(String directoryPath, String prefix) async {
      await for (final entity in Directory(
        directoryPath,
      ).list(followLinks: false)) {
        entries += 1;
        if (entries > _maxCleanSkinEntries) throw const _CleanSkinRejected();
        final name = p.basename(entity.path);
        final relativePath = prefix.isEmpty ? name : '$prefix/$name';
        if (!_isCleanSkinRelativePath(relativePath)) {
          throw const _CleanSkinRejected();
        }
        if (entity is Directory) {
          if (!index.add(relativePath, _CleanSkinEntryKind.directory)) {
            throw const _CleanSkinRejected();
          }
          await walk(entity.path, relativePath);
          continue;
        }
        if (entity is! File) throw const _CleanSkinRejected();
        if (!index.add(relativePath, _CleanSkinEntryKind.file)) {
          throw const _CleanSkinRejected();
        }
        final length = await entity.length();
        if (length > _maxCleanSkinFileBytes) {
          throw const _CleanSkinRejected();
        }
        totalBytes += length;
        if (totalBytes > _maxCleanSkinPackageBytes) {
          throw const _CleanSkinRejected();
        }
        sizes[relativePath] = length;
      }
    }

    await walk(rootPath, '');
    return sizes;
  }

  Future<Uint8List> _readCleanSkinInstalledFile(
    String path,
    int expectedSize,
  ) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in File(path).openRead(0, expectedSize + 1)) {
      total += chunk.length;
      if (total > expectedSize) throw const _CleanSkinRejected();
      builder.add(chunk);
    }
    if (total != expectedSize) throw const _CleanSkinRejected();
    return builder.takeBytes();
  }

  Future<Uint8List?> _loadBundledSkinAsset(String key) async {
    try {
      final data = await _bundledSkinAssets.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  Future<List<String>?> _readBundledSkinSourceIds() async {
    final bytes = await _loadBundledSkinAsset(_bundledSkinManifestAssetKey);
    if (bytes == null || bytes.length > _maxSkinManifestBytes) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (decoded is! List || decoded.length > _maxBundledSkinSourceCount) {
      return null;
    }
    final sourceIds = <String>[];
    for (final value in decoded) {
      if (value is! String ||
          !isSafePathComponent(value) ||
          sourceIds.contains(value)) {
        return null;
      }
      sourceIds.add(value);
    }
    return sourceIds;
  }

  _CleanSkinSourceScanResult _scanBundledSkinSource(
    String assetKey,
    Uint8List bytes,
    String skinId,
  ) {
    if (!_hasBoundedCleanSkinCentralDirectory(bytes)) {
      return const _CleanSkinSourceScanResult(_CleanSkinSourceScan.unsafe);
    }
    final ZipDirectory directory;
    try {
      directory = ZipDirectory()..read(_BoundedCleanSkinInput(bytes));
    } on _CleanSkinRejected {
      return const _CleanSkinSourceScanResult(_CleanSkinSourceScan.unsafe);
    } catch (_) {
      return const _CleanSkinSourceScanResult(_CleanSkinSourceScan.unsafe);
    }
    final headers = directory.fileHeaders;
    if (headers.isEmpty || headers.length > _maxCleanSkinEntries) {
      return const _CleanSkinSourceScanResult(_CleanSkinSourceScan.unsafe);
    }
    final layout = _validateCleanSkinArchiveLayout(headers);
    if (layout == null) {
      return const _CleanSkinSourceScanResult(_CleanSkinSourceScan.unsafe);
    }
    final declaration = _readCleanSkinArchiveDeclaration(layout);
    if (declaration == null) {
      return const _CleanSkinSourceScanResult(_CleanSkinSourceScan.unreadable);
    }
    if (declaration != skinId) {
      return const _CleanSkinSourceScanResult(_CleanSkinSourceScan.other);
    }
    return _CleanSkinSourceScanResult(
      _CleanSkinSourceScan.match,
      _CleanSkinBundledSource(
        assetKey: assetKey,
        headers: layout.headers,
        sizes: layout.sizes,
      ),
    );
  }

  String? _readCleanSkinArchiveDeclaration(_CleanSkinArchiveLayout layout) {
    final candidates = [
      for (final name in layout.headers.keys)
        if (name.split('/').length <= 2 &&
            _skinManifestNames.contains(name.split('/').last))
          name,
    ];
    final shallow = [
      for (final name in candidates)
        if (!name.contains('/')) name,
    ];
    final chosen = shallow.isEmpty ? candidates : shallow;
    if (chosen.length != 1) return null;
    final header = layout.headers[chosen.single];
    if (header == null || header.uncompressedSize > _maxSkinManifestBytes) {
      return null;
    }
    try {
      final decoded = jsonDecode(
        utf8.decode(_readCleanSkinArchiveContent(header)),
      );
      if (decoded is! Map) return null;
      final id = decoded['id'];
      return id is String ? id : null;
    } catch (_) {
      return null;
    }
  }

  _CleanSkinArchiveLayout? _validateCleanSkinArchiveLayout(
    List<ZipFileHeader> headers,
  ) {
    final kinds = <String, _CleanSkinEntryKind>{};
    final entries = <String, ZipFileHeader>{};
    for (final header in headers) {
      if (header.filename.contains('\\')) return null;
      final kind = _cleanSkinArchiveEntryKind(header);
      if (kind != _CleanSkinEntryKind.file &&
          kind != _CleanSkinEntryKind.directory) {
        return null;
      }
      final name = kind == _CleanSkinEntryKind.directory
          ? _stripCleanSkinTrailingSlashes(header.filename)
          : header.filename;
      if (!_isCleanSkinRelativePath(name) || entries.containsKey(name)) {
        return null;
      }
      kinds[name] = kind;
      entries[name] = header;
    }

    var prefix = '';
    final roots = {for (final name in entries.keys) name.split('/').first};
    if (roots.length == 1) {
      final root = roots.single;
      if (kinds[root] != _CleanSkinEntryKind.file) prefix = '$root/';
    }

    final index = _CleanSkinPathIndex();
    final sizes = <String, int>{};
    final files = <String, ZipFileHeader>{};
    var totalBytes = 0;
    var totalCompressedBytes = 0;
    for (final entry in entries.entries) {
      var name = entry.key;
      if (prefix.isNotEmpty) {
        if (!name.startsWith(prefix)) continue;
        name = name.substring(prefix.length);
      }
      if (!index.add(name, kinds[entry.key]!)) return null;
      if (kinds[entry.key] == _CleanSkinEntryKind.directory) continue;
      final header = entry.value;
      if ((header.generalPurposeBitFlag & 0x1) != 0) return null;
      if (header.compressionMethod != ZipFile.zipCompressionStore &&
          header.compressionMethod != ZipFile.zipCompressionDeflate) {
        return null;
      }
      final local = header.file;
      if (local == null) return null;
      if ((local.flags & 0x9) != (header.generalPurposeBitFlag & 0x9)) {
        return null;
      }
      if (local.filename != header.filename) return null;
      if (_cleanSkinCompressionCode(local.compressionMethod) !=
          header.compressionMethod) {
        return null;
      }
      if ((header.generalPurposeBitFlag & 0x8) == 0 &&
          local.crc32 != header.crc32) {
        return null;
      }
      if (header.uncompressedSize > _maxCleanSkinFileBytes) return null;
      totalBytes += header.uncompressedSize;
      totalCompressedBytes += header.compressedSize;
      if (totalBytes > _maxCleanSkinPackageBytes) return null;
      if (totalCompressedBytes > _maxCleanSkinPackageCompressedBytes) {
        return null;
      }
      sizes[name] = header.uncompressedSize;
      files[name] = header;
    }

    final entryPoint = sizes['index.html'];
    if (entryPoint == null || entryPoint == 0) return null;

    return _CleanSkinArchiveLayout(headers: files, sizes: sizes);
  }

  Future<CleanSkinSourceStatus?> _compareCleanSkinPackageContent(
    String packagePath,
    Map<String, int> installedSizes,
    _CleanSkinBundledSource source,
  ) async {
    if (installedSizes.length != source.sizes.length) {
      return CleanSkinSourceStatus.packageContentMismatch;
    }
    for (final entry in installedSizes.entries) {
      if (source.sizes[entry.key] != entry.value) {
        return CleanSkinSourceStatus.packageContentMismatch;
      }
      final Uint8List installedBytes;
      try {
        installedBytes = await _readCleanSkinInstalledFile(
          p.joinAll([packagePath, ...entry.key.split('/')]),
          entry.value,
        );
      } on _CleanSkinRejected {
        return CleanSkinSourceStatus.installedPackageUnreadable;
      } on FileSystemException {
        return CleanSkinSourceStatus.installedPackageUnreadable;
      }
      final Uint8List archivedBytes;
      try {
        archivedBytes = _readCleanSkinArchiveContent(
          source.headers[entry.key]!,
        );
      } on _CleanSkinRejected {
        return CleanSkinSourceStatus.bundledSourceUnsafe;
      }
      if (!listEquals(installedBytes, archivedBytes)) {
        return CleanSkinSourceStatus.packageContentMismatch;
      }
    }
    return null;
  }

  Future<String> installFromPath(
    String sourcePath, {
    bool overwriteIfExists = true,
  }) async {
    final source = File(sourcePath);
    final sourceDir = Directory(sourcePath);

    String skinId;
    if (source.existsSync() && sourcePath.endsWith('.zip')) {
      skinId = await _installFromZip(
        sourcePath,
        overwriteIfExists: overwriteIfExists,
      );
    } else if (sourceDir.existsSync()) {
      skinId = await _installFromDirectory(
        sourceDir,
        overwriteIfExists: overwriteIfExists,
      );
    } else {
      throw Exception('Source does not exist: $sourcePath');
    }

    await _scanInstalledSkins();
    return skinId;
  }

  Future<void> installFromUrl(
    String url, {
    String? sourceIdentifier,
    String? releaseAssetName,
    bool? includePrerelease,
  }) => _installFromUrl(
    url,
    sourceIdentifier: sourceIdentifier,
    releaseAssetName: releaseAssetName,
    includePrerelease: includePrerelease,
  );

  Future<void> _installFromUrl(
    String url, {
    String? sourceIdentifier,
    String? releaseAssetName,
    bool? includePrerelease,
    bool isReleaseDownload = false,
  }) async {
    _log.info('Downloading WebUI from URL: $url');

    try {
      final response = isReleaseDownload
          ? await releaseGet(url)
          : await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw remoteHttpError(response.statusCode);
      }
      final etag = response.headers['etag'];
      final lastModified = response.headers['last-modified'];

      final tempDir = await Directory(await AppDirectories.temp)
          .createTemp('webui_install');
      final tempFile = File('${tempDir.path}/skin.zip');
      await tempFile.writeAsBytes(response.bodyBytes);

      String installedSkinId;
      try {
        installedSkinId = await _installFromZip(tempFile.path);
      } finally {
        await tempDir.delete(recursive: true);
      }

      _skinMetadata[installedSkinId] = WebUIReaMetadata(
        skinId: installedSkinId,
        sourceUrl: sourceIdentifier ?? url,
        releaseAssetName: releaseAssetName,
        includePrerelease: includePrerelease,
        etag: etag,
        lastModified: lastModified,
        installedAt: DateTime.now(),
        lastChecked: DateTime.now(),
      );
      await _saveSkinMetadata();

      await _scanInstalledSkins();

      _log.info('Successfully installed WebUI from URL: $url');
    } catch (e) {
      _log.severe('Failed to install WebUI from URL: $url', e);
      rethrow;
    }
  }

  Future<void> installFromGitHub(String repo, {String branch = 'main'}) async {
    final parts = repo.split('/');
    if (parts.length < 2) {
      throw const UserFacingFormatException(
        'Invalid GitHub repo format. Use: owner/repo',
      );
    }

    final owner = parts[0];
    final repoName = parts[1];
    final branchName = parts.length > 2 ? parts[2] : branch;

    final url =
        'https://github.com/$owner/$repoName/archive/refs/heads/$branchName.zip';
    final sourceIdentifier = 'github_branch:$owner/$repoName@$branchName';

    await _installFromUrlAsRemoteBundled(
      url,
      markAsRemoteBundled: false,
      sourceIdentifier: sourceIdentifier,
    );
  }

  Future<void> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    final parts = repo.split('/');
    if (parts.length != 2) {
      throw const UserFacingFormatException(
        'Invalid GitHub repo format. Use: owner/repo',
      );
    }

    _log.info('Installing WebUI from GitHub release: $repo');

    try {
      final apiUrl = includePrerelease
          ? 'https://api.github.com/repos/$repo/releases'
          : 'https://api.github.com/repos/$repo/releases/latest';

      final releaseResponse = await _getGitHubRelease(apiUrl);

      final dynamic releaseData = includePrerelease
          ? (jsonDecode(releaseResponse.body) as List).first
          : jsonDecode(releaseResponse.body);

      final releaseTag = releaseData['tag_name'] as String;
      final releaseName = releaseData['name'] as String;
      final assets = releaseData['assets'] as List;

      _log.info('Found release: $releaseName ($releaseTag)');

      dynamic targetAsset;
      if (assetName != null) {
        targetAsset = assets.firstWhere(
          (asset) => asset['name'] == assetName,
          orElse: () =>
              throw UserFacingFormatException('Asset not found: $assetName'),
        );
      } else {
        targetAsset = assets.firstWhere(
          (asset) => (asset['name'] as String).endsWith('.zip'),
          orElse: () => throw const UserFacingFormatException(
            'No .zip asset found in release',
          ),
        );
      }

      final downloadUrl = targetAsset['browser_download_url'] as String;

      _log.info('Downloading asset: ${targetAsset['name']}');

      await _installFromUrl(
        downloadUrl,
        sourceIdentifier: 'github_release:$repo@$releaseTag',
        releaseAssetName: assetName,
        includePrerelease: includePrerelease,
        isReleaseDownload: true,
      );

      _log.info(
        'Successfully installed WebUI from GitHub release: $releaseTag',
      );
    } catch (e) {
      _log.severe('Failed to install WebUI from GitHub release: $repo', e);
      rethrow;
    }
  }

  Future<void> downloadRemoteSkins() =>
      _downloadRemoteSkinsCheck ??= _downloadRemoteSkins().whenComplete(
        () => _downloadRemoteSkinsCheck = null,
      );

  Future<void> _downloadRemoteSkins() async {
    final results = await checkRemoteBundledSkins();
    final failures = [
      for (final result in results)
        if (result.isFailure)
          (item: result.item, error: result.error as Object),
    ];
    if (failures.isNotEmpty) {
      throw RemoteUpdateException(
        attemptedCount: results.length,
        failures: failures,
      );
    }
  }

  Future<List<RemoteUpdateItemResult>> checkRemoteBundledSkins() =>
      _remoteDownload ??= _checkRemoteBundledSkins().whenComplete(
        () => _remoteDownload = null,
      );

  Future<List<RemoteUpdateItemResult>> _checkRemoteBundledSkins() async {
    final sources = await _getRemoteWebUISources();
    final results = <RemoteUpdateItemResult>[];
    for (final sourceConfig in sources) {
      final item = '${sourceConfig['repo'] ?? sourceConfig['url']}';
      try {
        final type = sourceConfig['type'] as String;

        switch (type) {
          case 'github_release':
            final repo = sourceConfig['repo'] as String;
            final asset = sourceConfig['asset'] as String?;
            final prerelease = sourceConfig['prerelease'] as bool? ?? false;

            _log.info(
              'Downloading remote bundled skin from GitHub release: $repo',
            );
            results.add(
              RemoteUpdateItemResult(
                item: item,
                status: await _installFromGitHubRelease(
                  repo,
                  asset,
                  prerelease,
                ),
              ),
            );
            break;

          case 'github_branch':
            final repo = sourceConfig['repo'] as String;
            final branch = sourceConfig['branch'] as String? ?? 'main';
            final url =
                'https://github.com/$repo/archive/refs/heads/$branch.zip';

            _log.info(
              'Downloading remote bundled skin from GitHub branch: $repo/$branch',
            );
            results.add(
              RemoteUpdateItemResult(
                item: item,
                status: await _installFromUrlAsRemoteBundled(url),
              ),
            );
            break;

          case 'url':
            final url = sourceConfig['url'] as String;

            _log.info('Downloading remote bundled skin from URL: $url');
            results.add(
              RemoteUpdateItemResult(
                item: item,
                status: await _installFromUrlAsRemoteBundled(url),
              ),
            );
            break;

          default:
            _log.warning('Unknown remote source type: $type');
            results.add(
              RemoteUpdateItemResult(
                item: sourceConfig['repo'] ?? sourceConfig['url'] ?? type,
                status: RemoteUpdateStatus.failed,
                error: FormatException('Unknown remote source type: $type'),
              ),
            );
        }
      } catch (e, st) {
        results.add(
          RemoteUpdateItemResult(
            item: item,
            status: RemoteUpdateStatus.failed,
            error: e,
          ),
        );
        _log.warning(
          'Failed to download remote skin from $sourceConfig',
          e,
          st,
        );
      }
    }
    return results;
  }

  Future<void> downloadRemoteSkinsAndRescan() async {
    try {
      await downloadRemoteSkins();
    } finally {
      await _scanInstalledSkins();
    }
  }

  Future<void> updateAllSkins() async {
    final report = await checkForSkinUpdates();
    if (report.hasFailures) {
      throw RemoteUpdateException(
        attemptedCount: report.results.length,
        failures: report.failures,
      );
    }
  }

  Future<RemoteUpdateReport> checkForSkinUpdates() {
    final existing = _updateCheckReport;
    if (existing != null) return existing;
    final report = _runSkinUpdates().whenComplete(() {
      _updateCheckReport = null;
      _updateCheck.value = null;
    });
    _updateCheckReport = report;
    _updateCheck.value = report.then<void>((_) {}).catchError((Object _) {});
    return report;
  }

  Future<RemoteUpdateReport> _runSkinUpdates() async {
    _log.info('Starting update check for all skins');
    final results = <RemoteUpdateItemResult>[
      ...await checkRemoteBundledSkins(),
      ...await _checkUserSkins(),
    ];
    await _scanInstalledSkins();
    _log.info('Finished update check for all skins');
    return RemoteUpdateReport(results);
  }

  Future<List<RemoteUpdateItemResult>> _checkUserSkins() async {
    final results = <RemoteUpdateItemResult>[];
    final userSkins = _skinMetadata.entries
        .where(
          (entry) =>
              entry.value.sourceUrl != null &&
              !_remoteBundledSkinIds.contains(entry.key),
        )
        .toList();

    for (final entry in userSkins) {
      final skinId = entry.key;
      final sourceUrl = entry.value.sourceUrl!;
      if (!sourceUrl.startsWith('github_release:') &&
          !sourceUrl.startsWith('github_branch:') &&
          !sourceUrl.startsWith('http')) {
        _log.fine(
          'Skipping skin "$skinId" with unsupported source type: $sourceUrl',
        );
        continue;
      }

      try {
        if (sourceUrl.startsWith('github_release:')) {
          final withoutPrefix = sourceUrl.substring('github_release:'.length);
          final atIndex = withoutPrefix.indexOf('@');
          final repo = atIndex >= 0
              ? withoutPrefix.substring(0, atIndex)
              : withoutPrefix;

          _log.info(
            'Updating user-installed skin "$skinId" from GitHub release: $repo',
          );
          results.add(
            RemoteUpdateItemResult(
              item: skinId,
              status: await _installFromGitHubRelease(
                repo,
                entry.value.releaseAssetName,
                entry.value.includePrerelease ?? false,
                markAsRemoteBundled: false,
                expectedSkinId: skinId,
              ),
            ),
          );
        } else if (sourceUrl.startsWith('github_branch:')) {
          final withoutPrefix = sourceUrl.substring('github_branch:'.length);
          final atIndex = withoutPrefix.indexOf('@');
          final repo = atIndex >= 0
              ? withoutPrefix.substring(0, atIndex)
              : withoutPrefix;
          final branch = atIndex >= 0
              ? withoutPrefix.substring(atIndex + 1)
              : 'main';

          _log.info(
            'Updating user-installed skin "$skinId" from GitHub branch: '
            '$repo@$branch',
          );
          final url = 'https://github.com/$repo/archive/refs/heads/$branch.zip';
          results.add(
            RemoteUpdateItemResult(
              item: skinId,
              status: await _installFromUrlAsRemoteBundled(
                url,
                markAsRemoteBundled: false,
                sourceIdentifier: 'github_branch:$repo@$branch',
                expectedSkinId: skinId,
              ),
            ),
          );
        } else {
          _log.info(
            'Updating user-installed skin "$skinId" from URL: $sourceUrl',
          );
          results.add(
            RemoteUpdateItemResult(
              item: skinId,
              status: await _installFromUrlAsRemoteBundled(
                sourceUrl,
                markAsRemoteBundled: false,
                expectedSkinId: skinId,
              ),
            ),
          );
        }
      } catch (e, st) {
        results.add(
          RemoteUpdateItemResult(
            item: skinId,
            status: RemoteUpdateStatus.failed,
            error: e,
          ),
        );
        _log.warning('Failed to update skin "$skinId" from $sourceUrl', e, st);
      }
    }

    return results;
  }

  Future<RemoteUpdateStatus> _installFromGitHubRelease(
    String repo,
    String? assetName,
    bool includePrerelease, {
    bool markAsRemoteBundled = true,
    String? expectedSkinId,
  }) async {
    try {
      final apiUrl = includePrerelease
          ? 'https://api.github.com/repos/$repo/releases'
          : 'https://api.github.com/repos/$repo/releases/latest';

      _log.fine('Fetching GitHub release info from: $apiUrl');

      final releaseResponse = await _getGitHubRelease(apiUrl);

      final dynamic releaseData = includePrerelease
          ? (jsonDecode(releaseResponse.body) as List).first
          : jsonDecode(releaseResponse.body);

      final releaseTag = releaseData['tag_name'] as String;
      final releaseName = releaseData['name'] as String;
      final publishedAt = releaseData['published_at'] as String;
      final assets = releaseData['assets'] as List;

      _log.info(
        'Found release: $releaseName ($releaseTag) published at $publishedAt',
      );

      dynamic targetAsset;
      if (assetName != null) {
        targetAsset = assets.firstWhere(
          (asset) => asset['name'] == assetName,
          orElse: () =>
              throw UserFacingFormatException('Asset not found: $assetName'),
        );
      } else {
        targetAsset = assets.firstWhere(
          (asset) => (asset['name'] as String).endsWith('.zip'),
          orElse: () => throw const UserFacingFormatException(
            'No .zip asset found in release',
          ),
        );
      }

      final downloadUrl = targetAsset['browser_download_url'] as String;
      final assetSize = targetAsset['size'] as int;

      _log.info(
        'Downloading asset: ${targetAsset['name']} (${(assetSize / 1024 / 1024).toStringAsFixed(2)} MB)',
      );

      final sourceIdentifier = 'github_release:$repo@$releaseTag';
      final existingMetadata = expectedSkinId != null
          ? _skinMetadata[expectedSkinId]
          : _skinMetadata.values
                .where((meta) => _tracksReleaseRepo(meta, repo))
                .firstOrNull;
      final boundSkinId = expectedSkinId ?? existingMetadata?.skinId;

      if (existingMetadata != null &&
          existingMetadata.sourceUrl == sourceIdentifier) {
        _log.info('Release $releaseTag already installed, skipping download');

        _skinMetadata[existingMetadata.skinId] = existingMetadata.copyWith(
          lastChecked: DateTime.now(),
        );
        await _saveSkinMetadata();
        return RemoteUpdateStatus.alreadyCurrent;
      }

      final assetResponse = await releaseGet(downloadUrl);
      if (assetResponse.statusCode != 200) {
        throw remoteHttpError(assetResponse.statusCode);
      }

      final tempDir = await Directory(await AppDirectories.temp)
          .createTemp('webui_install');
      final tempFile = File('${tempDir.path}/skin.zip');
      await tempFile.writeAsBytes(assetResponse.bodyBytes);

      String installedSkinId;
      try {
        installedSkinId = await _installFromZip(
          tempFile.path,
          expectedSkinId: boundSkinId,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }

      if (markAsRemoteBundled) {
        _remoteBundledSkinIds.add(installedSkinId);
        await _saveRemoteBundledSkinIds();
      }

      _skinMetadata[installedSkinId] = WebUIReaMetadata(
        skinId: installedSkinId,
        sourceUrl: sourceIdentifier,
        commitHash: releaseTag,
        releaseAssetName: assetName,
        includePrerelease: includePrerelease,
        etag: null,
        lastModified: publishedAt,
        installedAt: DateTime.now(),
        lastChecked: DateTime.now(),
      );
      await _saveSkinMetadata();

      _log.info(
        'Successfully installed skin from GitHub release: $installedSkinId ($releaseTag)',
      );

      await _scanInstalledSkins();
      return RemoteUpdateStatus.updated;
    } catch (e, st) {
      _log.severe('Failed to install from GitHub release: $repo', e, st);
      rethrow;
    }
  }

  bool _tracksReleaseRepo(WebUIReaMetadata metadata, String repo) =>
      metadata.sourceUrl?.startsWith('github_release:$repo@') ?? false;

  Future<RemoteUpdateStatus> _installFromUrlAsRemoteBundled(
    String url, {
    bool markAsRemoteBundled = true,
    String? sourceIdentifier,
    String? expectedSkinId,
  }) async {
    try {
      final headResponse = await http.head(Uri.parse(url));
      final etag = headResponse.headers['etag'];
      final lastModified = headResponse.headers['last-modified'];
      final trackedSource = sourceIdentifier ?? url;

      final existingMetadata = _skinMetadata.values.firstWhere(
        (meta) => meta.sourceUrl == trackedSource,
        orElse: () => WebUIReaMetadata(skinId: '', installedAt: DateTime.now()),
      );
      final boundSkinId =
          expectedSkinId ??
          (existingMetadata.skinId.isNotEmpty ? existingMetadata.skinId : null);

      bool needsUpdate = true;
      if (existingMetadata.skinId.isNotEmpty) {
        if (etag != null && etag == existingMetadata.etag) {
          needsUpdate = false;
          _log.info('Skin from $url is up to date (ETag match)');
        } else if (lastModified != null &&
            lastModified == existingMetadata.lastModified) {
          needsUpdate = false;
          _log.info('Skin from $url is up to date (Last-Modified match)');
        }
      }

      if (!needsUpdate) {
        _skinMetadata[existingMetadata.skinId] = existingMetadata.copyWith(
          lastChecked: DateTime.now(),
        );
        await _saveSkinMetadata();
        return RemoteUpdateStatus.alreadyCurrent;
      }

      _log.info('Downloading WebUI from URL: $url');

      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw remoteHttpError(response.statusCode);
      }

      final tempDir = await Directory(await AppDirectories.temp)
          .createTemp('webui_install');
      final tempFile = File('${tempDir.path}/skin.zip');
      await tempFile.writeAsBytes(response.bodyBytes);

      String? commitHash;

      if (url.contains('github.com')) {
        commitHash = _extractGitHubCommitHash(url);
      }

      String installedSkinId;
      try {
        installedSkinId = await _installFromZip(
          tempFile.path,
          expectedSkinId: boundSkinId,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }

      if (markAsRemoteBundled) {
        _remoteBundledSkinIds.add(installedSkinId);
        await _saveRemoteBundledSkinIds();
      }

      _skinMetadata[installedSkinId] = WebUIReaMetadata(
        skinId: installedSkinId,
        sourceUrl: trackedSource,
        etag: etag,
        lastModified: lastModified,
        commitHash: commitHash,
        installedAt: DateTime.now(),
        lastChecked: DateTime.now(),
      );
      await _saveSkinMetadata();

      _log.info('Installed/updated remote bundled skin: $installedSkinId');

      await _scanInstalledSkins();

      _log.info('Successfully installed remote bundled WebUI from URL: $url');
      return RemoteUpdateStatus.updated;
    } catch (e) {
      _log.severe('Failed to install WebUI from URL: $url', e);
      rethrow;
    }
  }

  String? _extractGitHubCommitHash(String url) {
    try {
      final match = RegExp(
        r'github\.com/([^/]+)/([^/]+)/archive/refs/heads/([^\.]+)\.zip',
      ).firstMatch(url);

      if (match != null) {
        final branch = match.group(3);
        return 'branch:$branch';
      }

      return null;
    } catch (e) {
      _log.warning('Failed to extract GitHub commit hash from URL: $url', e);
      return null;
    }
  }

  Future<void> removeSkin(String skinId) async {
    if (!_installedSkins.containsKey(skinId)) {
      throw Exception('Skin not found: $skinId');
    }

    final skin = _installedSkins[skinId]!;

    if (skin.isBundled) {
      throw Exception('Cannot remove bundled skin: $skinId');
    }

    final skinDir = Directory(skin.path);
    if (skinDir.existsSync()) {
      await skinDir.delete(recursive: true);
      _log.info('Removed skin: $skinId');
    }

    _installedSkins.remove(skinId);

    if (_skinMetadata.containsKey(skinId)) {
      _skinMetadata.remove(skinId);
      await _saveSkinMetadata();
    }
  }

  bool isSkinInstalled(String skinId) {
    return _installedSkins.containsKey(skinId);
  }

  String getSkinPath(String skinId) {
    final skin = _installedSkins[skinId];
    if (skin == null) {
      throw Exception('Skin not found: $skinId');
    }
    return skin.path;
  }

  Future<void> _loadRemoteBundledSkinIds() async {
    try {
      final registryFile = File(
        '${_webUIDir.path}/.remote_bundled_registry.json',
      );
      if (registryFile.existsSync()) {
        final contents = await registryFile.readAsString();
        final List<dynamic> skinIds = jsonDecode(contents);
        _remoteBundledSkinIds.addAll(skinIds.cast<String>());
        _log.fine(
          'Loaded ${_remoteBundledSkinIds.length} remote bundled skin IDs',
        );
      }
    } catch (e) {
      _log.warning('Failed to load remote bundled skin IDs registry', e);
    }
  }

  Future<void> _saveRemoteBundledSkinIds() async {
    try {
      final registryFile = File(
        '${_webUIDir.path}/.remote_bundled_registry.json',
      );
      await registryFile.writeAsString(
        jsonEncode(_remoteBundledSkinIds.toList()),
      );
      _log.fine(
        'Saved ${_remoteBundledSkinIds.length} remote bundled skin IDs',
      );
    } catch (e) {
      _log.warning('Failed to save remote bundled skin IDs registry', e);
    }
  }

  Future<void> _loadSkinMetadata() async {
    try {
      final metadataFile = File('${_webUIDir.path}/.rea_metadata.json');
      if (metadataFile.existsSync()) {
        final contents = await metadataFile.readAsString();
        final Map<String, dynamic> json = jsonDecode(contents);

        for (final entry in json.entries) {
          _skinMetadata[entry.key] = WebUIReaMetadata.fromJson(
            entry.value as Map<String, dynamic>,
          );
        }

        _log.fine('Loaded metadata for ${_skinMetadata.length} skins');
      }
    } catch (e) {
      _log.warning('Failed to load skin metadata', e);
    }
  }

  Future<void> _saveSkinMetadata() async {
    try {
      final metadataFile = File('${_webUIDir.path}/.rea_metadata.json');
      final json = <String, dynamic>{};

      for (final entry in _skinMetadata.entries) {
        json[entry.key] = entry.value.toJson();
      }

      await metadataFile.writeAsString(
        JsonEncoder.withIndent('  ').convert(json),
      );
      _log.fine('Saved metadata for ${_skinMetadata.length} skins');
    } catch (e) {
      _log.warning('Failed to save skin metadata', e);
    }
  }

  Future<void> _copyBundledSkins() async {
    for (final assetPath in _bundledAssetPaths) {
      try {
        final skinId = assetPath.split('/').where((s) => s.isNotEmpty).last;
        final destDir = Directory('${_webUIDir.path}/$skinId');

        if (destDir.existsSync() && destDir.listSync().isNotEmpty) {
          _log.fine('Bundled skin already exists: $skinId');
          continue;
        }

        destDir.createSync(recursive: true);

        await _copyAssetFolder(assetPath, destDir.path);

        _log.info('Copied bundled skin: $skinId');
      } catch (e) {
        _log.warning('Failed to copy bundled skin from $assetPath', e);
      }
    }

    List<String> skinIds;
    try {
      final manifestString = await rootBundle.loadString(
        'assets/bundled_skins/manifest.json',
      );
      skinIds = (jsonDecode(manifestString) as List).cast<String>();
    } catch (e, st) {
      _log.warning('Failed to load bundled skins manifest', e, st);
      return;
    }

    await installBundledSkinList(skinIds, (skinId) async {
      final destDir = Directory('${_webUIDir.path}/$skinId');
      if (destDir.existsSync() && destDir.listSync().isNotEmpty) {
        _log.fine('Bundled skin already exists: $skinId');
        return;
      }

      final zipData = await rootBundle.load('assets/bundled_skins/$skinId.zip');
      final tempFile = File('${_webUIDir.path}/$skinId.zip');
      await tempFile.writeAsBytes(zipData.buffer.asUint8List());

      try {
        await _installFromZip(tempFile.path, overwriteIfExists: false);
        _log.info('Installed bundled skin from asset: $skinId');
      } finally {
        if (tempFile.existsSync()) await tempFile.delete();
      }
    }, log: _log);
  }

  Future<void> _copyAssetFolder(String assetPath, String destPath) async {
    try {
      final commonFiles = [
        'index.html',
        'style.css',
        'script.js',
        'app.js',
        'main.js',
        'favicon.ico',
        'manifest.json',
        'README.md',
      ];

      for (final fileName in commonFiles) {
        try {
          final assetFile = '$assetPath$fileName';
          final content = await rootBundle.loadString(assetFile);
          final destFile = File('$destPath/$fileName');
          await destFile.writeAsString(content);
          _log.fine('Copied asset file: $fileName');
        } catch (e) {
          continue;
        }
      }
    } catch (e) {
      _log.warning('Error copying asset folder $assetPath', e);
      rethrow;
    }
  }

  Future<void> _scanInstalledSkins() async {
    final installedSkins = <String, WebUISkin>{};
    final skinPaths = <String, List<String>>{};

    if (!_webUIDir.existsSync()) {
      _installedSkins.clear();
      _skinPaths.clear();
      return;
    }

    final directories = _webUIDir.listSync().whereType<Directory>().where(
      (dir) => p.basename(dir.path) != _stagingDirName,
    );

    for (final dir in directories) {
      try {
        final skinId = p.basename(dir.path);

        final reaMetadata = _skinMetadata[skinId];

        final skinManifestFile = File('${dir.path}/skin-manifest.json');
        final manifestFile = File('${dir.path}/manifest.json');
        WebUISkin skin;

        Map<String, dynamic>? skinMeta;
        if (skinManifestFile.existsSync()) {
          skinMeta = jsonDecode(
            await skinManifestFile.readAsString(),
          ) as Map<String, dynamic>;
        } else if (manifestFile.existsSync()) {
          skinMeta = jsonDecode(
            await manifestFile.readAsString(),
          ) as Map<String, dynamic>;
        }

        if (skinMeta != null) {
          skin = WebUISkin(
            id: skinMeta['id'] as String? ?? skinId,
            name: skinMeta['name'] as String? ?? skinId,
            path: dir.path,
            description: skinMeta['description'] as String?,
            version: skinMeta['version'] as String?,
            isBundled: _isBundledSkin(skinId),
            reaMetadata: reaMetadata,
          );
        } else {
          skin = WebUISkin(
            id: skinId,
            name: skinId,
            path: dir.path,
            isBundled: _isBundledSkin(skinId),
            reaMetadata: reaMetadata,
          );
        }

        if (!isSafePathComponent(skin.id)) {
          _log.warning(
            'Skipping skin with unsafe id "${skin.id}" at ${dir.path}',
          );
          continue;
        }

        (skinPaths[skin.id] ??= []).add(skin.path);
        final existing = installedSkins[skin.id];
        if (existing != null && p.basename(existing.path) == skin.id) {
          continue;
        }
        installedSkins[skin.id] = skin;
        _log.fine('Found skin: ${skin.id} at ${skin.path}');
      } catch (e) {
        _log.warning('Failed to load skin from ${dir.path}', e);
      }
    }
    _installedSkins
      ..clear()
      ..addAll(installedSkins);
    _skinPaths
      ..clear()
      ..addAll(skinPaths);
  }

  bool _isBundledSkin(String skinId) {
    final isAssetBundled = _bundledAssetPaths.any((path) {
      final bundledId = path.split('/').where((s) => s.isNotEmpty).last;
      return bundledId == skinId;
    });

    if (isAssetBundled) return true;

    return _remoteBundledSkinIds.contains(skinId);
  }

  Future<String> _installFromZip(
    String zipPath, {
    bool overwriteIfExists = true,
    String? expectedSkinId,
  }) async {
    _log.info('Installing WebUI from zip: $zipPath');

    final tempDir = await Directory(await AppDirectories.temp)
        .createTemp('webui_extract');

    try {
      final bytes = await File(zipPath).readAsBytes();
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(bytes);
      } catch (e, st) {
        _log.warning('Failed to decode skin archive: $zipPath', e, st);
        throw const UserFacingFormatException(
          'The file is not a valid skin archive.',
        );
      }
      if (archive.files.isEmpty) {
        _log.warning('Skin archive has no entries: $zipPath');
        throw const UserFacingFormatException(
          'The file is not a valid skin archive.',
        );
      }

      final ExtractionResult extraction;
      try {
        extraction = extractArchiveToDirectory(
          archive,
          tempDir,
          sanitize: Platform.isWindows,
          strict: true,
          log: _log,
        );
      } catch (e, st) {
        _log.warning('Failed to extract skin archive: $zipPath', e, st);
        throw const UserFacingFormatException(
          'The skin archive is damaged and could not be extracted.',
        );
      }
      if (extraction.extracted == 0) {
        _log.warning('Skin archive contains no files: $zipPath');
        throw const UserFacingFormatException(
          'The skin archive does not contain any files.',
        );
      }

      return await _installFromDirectory(
        _selectCandidateRoot(tempDir),
        overwriteIfExists: overwriteIfExists,
        expectedSkinId: expectedSkinId,
      );
    } finally {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  Directory _selectCandidateRoot(Directory extractDir) {
    final extractedContents = extractDir.listSync();
    if (extractedContents.length == 1 && extractedContents.first is Directory) {
      return extractedContents.first as Directory;
    }
    return extractDir;
  }

  Future<String> _installFromDirectory(
    Directory sourceDir, {
    bool overwriteIfExists = true,
    String? expectedSkinId,
  }) async {
    final declaredSkinId = await _readCandidateSkinId(sourceDir);
    final skinId =
        expectedSkinId ?? declaredSkinId ?? p.basename(sourceDir.path);

    if (!isSafePathComponent(skinId)) {
      throw const UserFacingFormatException(
        'Unsafe skin id: must be a single safe path component',
      );
    }

    if (skinId == _stagingDirName || declaredSkinId == _stagingDirName) {
      throw const UserFacingFormatException(
        'The skin package declares a reserved skin id.',
      );
    }

    if (expectedSkinId != null &&
        declaredSkinId != null &&
        declaredSkinId != expectedSkinId) {
      throw const UserFacingFormatException(
        'The skin package declares a different skin id than the installed '
        'skin.',
      );
    }

    if (!File('${sourceDir.path}/index.html').existsSync()) {
      throw const UserFacingFormatException(
        'The skin package does not contain an index.html file.',
      );
    }

    final destDir = Directory('${_webUIDir.path}/$skinId');
    final destExists = destDir.existsSync();
    final destHasFiles = destExists && destDir.listSync().isNotEmpty;
    if (destHasFiles && !overwriteIfExists) {
      _log.info(
        'Skin "$skinId" already installed; skipping to avoid clobbering existing copy',
      );
      return skinId;
    }

    await _replaceInstalledSkin(
      sourceDir,
      destDir,
      replaceExisting: destExists,
    );

    _log.info('Installed WebUI skin: $skinId at ${destDir.path}');

    return skinId;
  }

  static const _manifestStringFields = ['id', 'name', 'description', 'version'];

  Future<String?> _readCandidateSkinId(Directory sourceDir) async {
    for (final manifestName in const ['skin-manifest.json', 'manifest.json']) {
      final manifestFile = File('${sourceDir.path}/$manifestName');
      if (!manifestFile.existsSync()) continue;

      final Map<String, dynamic> manifest;
      try {
        manifest = jsonDecode(
          await manifestFile.readAsString(),
        ) as Map<String, dynamic>;
      } catch (e, st) {
        _log.warning(
          'Failed to read $manifestName in ${sourceDir.path}',
          e,
          st,
        );
        throw const UserFacingFormatException(
          'The skin manifest is not valid JSON.',
        );
      }

      for (final field in _manifestStringFields) {
        final value = manifest[field];
        if (value == null || value is String) continue;
        _log.warning(
          'Skin manifest $manifestName in ${sourceDir.path} has a non-string '
          '"$field": $value',
        );
        throw UserFacingFormatException(
          'The skin manifest has an invalid "$field" value.',
        );
      }

      return manifest['id'] as String?;
    }

    return null;
  }

  Future<void> _replaceInstalledSkin(
    Directory sourceDir,
    Directory destDir, {
    required bool replaceExisting,
  }) async {
    final stagingRoot = Directory('${_webUIDir.path}/$_stagingDirName')
      ..createSync(recursive: true);
    Directory? candidate;
    Directory? previous;
    var keepPrevious = false;

    try {
      candidate = stagingRoot.createTempSync('candidate_');
      await copySkinFiles(sourceDir, candidate);

      if (replaceExisting) {
        previous = _reserveDirectoryPath(stagingRoot, 'previous_');
        try {
          await moveSkinDirectory(destDir, previous);
        } catch (e, st) {
          _log.severe('Failed to move aside ${destDir.path}', e, st);
          rethrow;
        }
      }

      try {
        await moveSkinDirectory(candidate, destDir);
        candidate = null;
      } catch (e, st) {
        _log.severe(
          'Failed to move the staged skin into ${destDir.path}',
          e,
          st,
        );
        final movedAside = previous;
        if (movedAside != null) {
          try {
            await moveSkinDirectory(movedAside, destDir);
            previous = null;
          } catch (restoreError, restoreStack) {
            keepPrevious = true;
            _log.severe(
              'Failed to restore the previous skin at ${destDir.path}; '
              'it is preserved at ${movedAside.path}',
              restoreError,
              restoreStack,
            );
          }
        }
        rethrow;
      }
    } finally {
      if (candidate != null) _deleteDirectoryQuietly(candidate);
      if (!keepPrevious && previous != null) {
        _deleteDirectoryQuietly(previous);
      }
      if (stagingRoot.existsSync() && stagingRoot.listSync().isEmpty) {
        _deleteDirectoryQuietly(stagingRoot);
      }
    }
  }

  Directory _reserveDirectoryPath(Directory parent, String prefix) {
    final reserved = parent.createTempSync(prefix);
    reserved.deleteSync();
    return reserved;
  }

  void _deleteDirectoryQuietly(Directory directory) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } catch (e, st) {
      _log.warning('Failed to clean up ${directory.path}', e, st);
    }
  }

  @visibleForTesting
  Future<void> copySkinFiles(Directory source, Directory destination) =>
      _copyDirectory(source, destination);

  @visibleForTesting
  Future<void> moveSkinDirectory(
    Directory source,
    Directory destination,
  ) async {
    await source.rename(destination.path);
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await for (final entity in source.list(recursive: false)) {
      final fileName = p.basename(entity.path);

      if (entity is File) {
        final newFile = File(p.join(destination.path, fileName));
        await entity.copy(newFile.path);
      } else if (entity is Directory) {
        final newDir = Directory(p.join(destination.path, fileName));
        newDir.createSync(recursive: true);
        await _copyDirectory(entity, newDir);
      }
    }
  }

  Future<void> reset() async {
    for (final skin in _installedSkins.values.toList()) {
      if (!skin.isBundled) {
        try {
          await removeSkin(skin.id);
        } catch (e) {
          _log.warning('Failed to remove skin during reset: ${skin.id}', e);
        }
      }
    }

    await _scanInstalledSkins();
  }
}
