import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

const String _manifestAssetKey = 'assets/bundled_skins/manifest.json';
const String _flatSkinId = 'test.skin';

final bool _realBundledSkinAvailable = File(
  p.join('assets', 'bundled_skins', 'WorkFlow-Skin.zip'),
).existsSync();

String _sourceAssetKey(String sourceId) => 'assets/bundled_skins/$sourceId.zip';

base class _RecordingPreferences extends SharedPreferencesAsyncPlatform {
  final values = <String, Object>{};
  final writes = <String>[];

  void _recordWrite(String key) {
    writes.add(key);
  }

  @override
  Future<void> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
    values[key] = value;
  }

  @override
  Future<void> setBool(
    String key,
    bool value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
    values[key] = value;
  }

  @override
  Future<void> setDouble(
    String key,
    double value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
    values[key] = value;
  }

  @override
  Future<void> setInt(
    String key,
    int value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
    values[key] = value;
  }

  @override
  Future<void> setStringList(
    String key,
    List<String> value,
    SharedPreferencesOptions options,
  ) async {
    _recordWrite(key);
    values[key] = value;
  }

  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async => values[key] as String?;

  @override
  Future<bool?> getBool(String key, SharedPreferencesOptions options) async =>
      values[key] as bool?;

  @override
  Future<double?> getDouble(
    String key,
    SharedPreferencesOptions options,
  ) async => values[key] as double?;

  @override
  Future<int?> getInt(String key, SharedPreferencesOptions options) async =>
      values[key] as int?;

  @override
  Future<List<String>?> getStringList(
    String key,
    SharedPreferencesOptions options,
  ) async => values[key] as List<String>?;

  @override
  Future<void> clear(
    ClearPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async {
    values.clear();
  }

  @override
  Future<Map<String, Object>> getPreferences(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async => Map<String, Object>.of(values);

  @override
  Future<Set<String>> getKeys(
    GetPreferencesParameters parameters,
    SharedPreferencesOptions options,
  ) async => values.keys.toSet();
}

class _MapAssetBundle extends AssetBundle {
  _MapAssetBundle(this.assets);

  final Map<String, Uint8List> assets;
  final List<String> loads = [];

  @override
  Future<ByteData> load(String key) async {
    loads.add(key);
    final bytes = assets[key];
    if (bytes == null) {
      throw FlutterError('Unable to load asset: "$key".');
    }
    return ByteData.sublistView(bytes);
  }
}

Uint8List _utf8Bytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

_MapAssetBundle _bundle({
  required List<String> sourceIds,
  Map<String, Uint8List> sources = const {},
  Object? manifest,
  Uint8List? manifestBytes,
}) {
  return _MapAssetBundle({
    _manifestAssetKey: manifestBytes ?? _utf8Bytes(manifest ?? sourceIds),
    for (final entry in sources.entries)
      _sourceAssetKey(entry.key): entry.value,
  });
}

Uint8List _encodeZip(Archive archive) =>
    Uint8List.fromList(ZipEncoder().encode(archive));

final class _EntryListArchive extends Archive {
  _EntryListArchive(this._entries);

  final List<ArchiveFile> _entries;

  @override
  Iterator<ArchiveFile> get iterator => _entries.iterator;
}

String _entryName(String root, String name) =>
    root.isEmpty ? name : '$root/$name';

Uint8List _skinZip({
  required String id,
  String root = '',
  String manifestName = 'skin-manifest.json',
  String indexHtml = '<html>skin</html>',
  bool includeIndex = true,
  Map<String, String> files = const {},
  List<ArchiveFile> extraEntries = const [],
  CompressionType? compression,
}) {
  final archive = Archive();
  if (root.isNotEmpty) {
    archive.addFile(ArchiveFile.directory('$root/'));
  }
  archive.addFile(
    ArchiveFile.string(
      _entryName(root, manifestName),
      jsonEncode({'id': id, 'name': id}),
    ),
  );
  if (includeIndex) {
    archive.addFile(
      ArchiveFile.string(_entryName(root, 'index.html'), indexHtml),
    );
  }
  files.forEach((name, content) {
    archive.addFile(ArchiveFile.string(_entryName(root, name), content));
  });
  for (final entry in extraEntries) {
    archive.addFile(entry);
  }
  if (compression != null) {
    for (final entry in archive) {
      entry.compression = compression;
    }
  }
  return _encodeZip(archive);
}

int? _centralEntryOffset(Uint8List zip, String name) {
  const centralSignature = [0x50, 0x4b, 0x01, 0x02];
  final encodedName = utf8.encode(name);
  for (var offset = 0; offset + 46 <= zip.length; offset++) {
    if (!_matchesAt(zip, offset, centralSignature)) continue;
    final nameLength = zip[offset + 28] | (zip[offset + 29] << 8);
    if (nameLength != encodedName.length) continue;
    if (!_matchesAt(zip, offset + 46, encodedName)) continue;
    return offset;
  }
  return null;
}

int _uint32At(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

void _writeUint32(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = (value >> 16) & 0xff;
  bytes[offset + 3] = (value >> 24) & 0xff;
}

void _writeUint64(Uint8List bytes, int offset, int value) {
  for (var index = 0; index < 8; index++) {
    bytes[offset + index] = (value >> (8 * index)) & 0xff;
  }
}

Uint8List _patchCentralEntry(
  Uint8List zip,
  String name, {
  int? uncompressedSize,
  int? compressedSize,
  int? crc32,
  int? compressionMethod,
}) {
  final bytes = Uint8List.fromList(zip);
  final offset = _centralEntryOffset(bytes, name);
  if (offset == null) fail('central directory entry "$name" not found');
  if (uncompressedSize != null) {
    _writeUint32(bytes, offset + 24, uncompressedSize);
  }
  if (compressedSize != null) {
    _writeUint32(bytes, offset + 20, compressedSize);
  }
  if (crc32 != null) {
    _writeUint32(bytes, offset + 16, crc32);
  }
  if (compressionMethod != null) {
    bytes[offset + 10] = compressionMethod & 0xff;
    bytes[offset + 11] = (compressionMethod >> 8) & 0xff;
  }
  return bytes;
}

int _centralCrc(Uint8List zip, String name) {
  final offset = _centralEntryOffset(zip, name);
  if (offset == null) fail('central directory entry "$name" not found');
  return _uint32At(zip, offset + 16);
}

int _centralCompressedSize(Uint8List zip, String name) {
  final offset = _centralEntryOffset(zip, name);
  if (offset == null) fail('central directory entry "$name" not found');
  return _uint32At(zip, offset + 20);
}

int _localHeaderOffset(Uint8List zip, String name) {
  final offset = _centralEntryOffset(zip, name);
  if (offset == null) fail('central directory entry "$name" not found');
  final localHeader = _uint32At(zip, offset + 42);
  if (localHeader + 30 > zip.length) {
    fail('local header for "$name" is outside the archive');
  }
  return localHeader;
}

int _localPayloadOffset(Uint8List zip, String name) {
  final localHeader = _localHeaderOffset(zip, name);
  final nameLength = zip[localHeader + 26] | (zip[localHeader + 27] << 8);
  final extraLength = zip[localHeader + 28] | (zip[localHeader + 29] << 8);
  return localHeader + 30 + nameLength + extraLength;
}

Uint8List _patchLocalHeader(
  Uint8List zip,
  String name, {
  int? flags,
  String? filename,
  int? crc32,
}) {
  final bytes = Uint8List.fromList(zip);
  final localHeader = _localHeaderOffset(bytes, name);
  if (flags != null) {
    bytes[localHeader + 6] = flags & 0xff;
    bytes[localHeader + 7] = (flags >> 8) & 0xff;
  }
  if (crc32 != null) {
    _writeUint32(bytes, localHeader + 14, crc32);
  }
  if (filename != null) {
    final encoded = utf8.encode(filename);
    final nameLength = bytes[localHeader + 26] | (bytes[localHeader + 27] << 8);
    if (encoded.length != nameLength) {
      fail('local filename "$filename" must keep the original length');
    }
    bytes.setRange(
      localHeader + 30,
      localHeader + 30 + encoded.length,
      encoded,
    );
  }
  return bytes;
}

Uint8List _clearDeflateFinalFlag(Uint8List zip, String name) {
  final bytes = Uint8List.fromList(zip);
  final payload = _localPayloadOffset(bytes, name);
  final offset = _centralEntryOffset(bytes, name);
  if (offset == null) fail('central directory entry "$name" not found');
  if (bytes[offset + 10] != 8 || bytes[offset + 11] != 0) {
    fail('entry "$name" is not deflate compressed');
  }
  bytes[payload] &= 0xfe;
  return bytes;
}

int _endOfCentralDirectoryOffset(Uint8List zip) {
  for (var offset = zip.length - 22; offset >= 0; offset--) {
    if (zip[offset] != 0x50 ||
        zip[offset + 1] != 0x4b ||
        zip[offset + 2] != 0x05 ||
        zip[offset + 3] != 0x06) {
      continue;
    }
    return offset;
  }
  fail('end of central directory record not found');
}

Uint8List _zip64AlternateCentralDirectory(Uint8List zip) {
  final end = _endOfCentralDirectoryOffset(zip);
  final directoryOffset = _uint32At(zip, end + 16);
  final directorySize = _uint32At(zip, end + 12);
  final entries = zip[end + 10] | (zip[end + 11] << 8);
  final head = Uint8List.fromList(zip.sublist(0, end));
  final decoyName = utf8.encode('decoy.txt');
  final decoy = Uint8List(46 + decoyName.length);
  decoy[0] = 0x50;
  decoy[1] = 0x4b;
  decoy[2] = 0x01;
  decoy[3] = 0x02;
  decoy[28] = decoyName.length & 0xff;
  decoy.setRange(46, 46 + decoyName.length, decoyName);
  final decoyOffset = head.length;
  final zip64EndOffset = decoyOffset + decoy.length;
  final locatorOffset = zip64EndOffset + 56;
  final classicEndOffset = locatorOffset + 20;
  final bytes = Uint8List(classicEndOffset + 22);
  bytes.setRange(0, head.length, head);
  bytes.setRange(decoyOffset, zip64EndOffset, decoy);
  _writeUint32(bytes, zip64EndOffset, 0x06064b50);
  _writeUint64(bytes, zip64EndOffset + 4, 44);
  bytes[zip64EndOffset + 12] = 45;
  bytes[zip64EndOffset + 14] = 45;
  _writeUint64(bytes, zip64EndOffset + 24, entries);
  _writeUint64(bytes, zip64EndOffset + 32, entries);
  _writeUint64(bytes, zip64EndOffset + 40, directorySize);
  _writeUint64(bytes, zip64EndOffset + 48, directoryOffset);
  _writeUint32(bytes, locatorOffset, 0x07064b50);
  _writeUint64(bytes, locatorOffset + 8, zip64EndOffset);
  _writeUint32(bytes, locatorOffset + 16, 1);
  _writeUint32(bytes, classicEndOffset, 0x06054b50);
  bytes[classicEndOffset + 8] = 1;
  bytes[classicEndOffset + 10] = 1;
  _writeUint32(bytes, classicEndOffset + 12, decoy.length);
  _writeUint32(bytes, classicEndOffset + 16, decoyOffset);
  return bytes;
}

Uint8List _zip64ChunkBoundaryArchive(Uint8List zip) {
  const padding = 1024;
  const commentLength = 1007;
  final end = _endOfCentralDirectoryOffset(zip);
  final directoryOffset = _uint32At(zip, end + 16);
  final directorySize = _uint32At(zip, end + 12);
  final entries = zip[end + 10] | (zip[end + 11] << 8);
  final head = Uint8List.fromList(zip.sublist(0, end));
  final decoyName = utf8.encode('decoy.txt');
  final decoy = Uint8List(46 + decoyName.length);
  decoy[0] = 0x50;
  decoy[1] = 0x4b;
  decoy[2] = 0x01;
  decoy[3] = 0x02;
  decoy[28] = decoyName.length & 0xff;
  decoy.setRange(46, 46 + decoyName.length, decoyName);
  final decoyOffset = head.length;
  final zip64EndOffset = decoyOffset + decoy.length;
  final locatorOffset = zip64EndOffset + 56 + padding;
  final earlierEndOffset = locatorOffset + 20;
  final finalEndOffset = earlierEndOffset + 22;
  final bytes = Uint8List(finalEndOffset + 22 + commentLength);
  bytes.setRange(0, head.length, head);
  bytes.setRange(decoyOffset, zip64EndOffset, decoy);
  _writeUint32(bytes, zip64EndOffset, 0x06064b50);
  _writeUint64(bytes, zip64EndOffset + 4, 44);
  bytes[zip64EndOffset + 12] = 45;
  bytes[zip64EndOffset + 14] = 45;
  _writeUint64(bytes, zip64EndOffset + 24, entries);
  _writeUint64(bytes, zip64EndOffset + 32, entries);
  _writeUint64(bytes, zip64EndOffset + 40, directorySize);
  _writeUint64(bytes, zip64EndOffset + 48, directoryOffset);
  _writeUint32(bytes, locatorOffset, 0x07064b50);
  _writeUint64(bytes, locatorOffset + 8, zip64EndOffset);
  _writeUint32(bytes, locatorOffset + 16, 1);
  _writeUint32(bytes, earlierEndOffset, 0x06054b50);
  bytes[earlierEndOffset + 8] = 1;
  bytes[earlierEndOffset + 10] = 1;
  _writeUint32(bytes, earlierEndOffset + 12, decoy.length);
  _writeUint32(bytes, earlierEndOffset + 16, decoyOffset);
  _writeUint32(bytes, finalEndOffset, 0x06054b50);
  bytes[finalEndOffset + 8] = 1;
  bytes[finalEndOffset + 10] = 1;
  _writeUint32(bytes, finalEndOffset + 12, decoy.length);
  _writeUint32(bytes, finalEndOffset + 16, decoyOffset);
  bytes[finalEndOffset + 20] = commentLength & 0xff;
  bytes[finalEndOffset + 21] = (commentLength >> 8) & 0xff;
  return bytes;
}

Uint8List _patchEndOfCentralDirectoryCount(Uint8List zip, int declared) {
  final bytes = Uint8List.fromList(zip);
  final offset = _endOfCentralDirectoryOffset(bytes);
  bytes[offset + 8] = declared & 0xff;
  bytes[offset + 9] = (declared >> 8) & 0xff;
  bytes[offset + 10] = declared & 0xff;
  bytes[offset + 11] = (declared >> 8) & 0xff;
  return bytes;
}

List<int> _centralRecordOffsets(Uint8List zip) {
  final end = _endOfCentralDirectoryOffset(zip);
  final entries = zip[end + 10] | (zip[end + 11] << 8);
  var cursor = _uint32At(zip, end + 16);
  final offsets = <int>[];
  for (var index = 0; index < entries; index++) {
    offsets.add(cursor);
    cursor +=
        46 +
        (zip[cursor + 28] | (zip[cursor + 29] << 8)) +
        (zip[cursor + 30] | (zip[cursor + 31] << 8)) +
        (zip[cursor + 32] | (zip[cursor + 33] << 8));
  }
  return offsets;
}

Uint8List _sharedLocalHeaderArchive() {
  final archive = Archive();
  archive.addFile(
    ArchiveFile.string(
      'skin-manifest.json',
      jsonEncode({'id': _flatSkinId, 'name': _flatSkinId}),
    ),
  );
  archive.addFile(ArchiveFile.string('index.html', '<html>skin</html>'));
  archive.addFile(
    ArchiveFile.string('payload.bin', 'P' * (48 * 1024))
      ..compression = CompressionType.none,
  );
  for (var index = 0; index < 4092; index++) {
    archive.addFile(ArchiveFile.string('f$index.js', 'x'));
  }
  final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
  final shared = _uint32At(
    bytes,
    _centralEntryOffset(bytes, 'payload.bin')! + 42,
  );
  final payloadBytes = 48 * 1024;
  for (final offset in _centralRecordOffsets(bytes)) {
    _writeUint32(bytes, offset + 20, payloadBytes);
    _writeUint32(bytes, offset + 24, payloadBytes);
    _writeUint32(bytes, offset + 42, shared);
  }
  return bytes;
}

Uint8List _corruptEntryPayload(Uint8List zip, String name) {
  final bytes = Uint8List.fromList(zip);
  final offset = _centralEntryOffset(bytes, name);
  if (offset == null) fail('central directory entry "$name" not found');
  final localHeader = _uint32At(bytes, offset + 42);
  final nameLength = bytes[localHeader + 26] | (bytes[localHeader + 27] << 8);
  final extraLength = bytes[localHeader + 28] | (bytes[localHeader + 29] << 8);
  final payloadStart = localHeader + 30 + nameLength + extraLength;
  final compressedSize = _uint32At(bytes, offset + 20);
  for (var index = 0; index < compressedSize; index++) {
    bytes[payloadStart + index] = 0xbe;
  }
  return bytes;
}

Future<ByteData?> Function(ByteData?) _assetChannel(
  Map<String, List<int>> assets,
) {
  return (message) async {
    final key = const StringCodec().decodeMessage(message);
    final bytes = assets[key];
    if (bytes == null) return null;
    return ByteData.sublistView(Uint8List.fromList(bytes));
  };
}

bool _matchesAt(Uint8List bytes, int offset, List<int> pattern) {
  if (offset + pattern.length > bytes.length) return false;
  for (var index = 0; index < pattern.length; index++) {
    if (bytes[offset + index] != pattern[index]) return false;
  }
  return true;
}

Uint8List _withUnixSymlinkEntry(Uint8List zip, String entryName) {
  const centralDirectorySignature = [0x50, 0x4b, 0x01, 0x02];
  final bytes = Uint8List.fromList(zip);
  final encodedName = utf8.encode(entryName);
  for (var offset = 0; offset + 46 <= bytes.length; offset++) {
    if (!_matchesAt(bytes, offset, centralDirectorySignature)) continue;
    final nameLength = bytes[offset + 28] | (bytes[offset + 29] << 8);
    if (nameLength != encodedName.length) continue;
    if (!_matchesAt(bytes, offset + 46, encodedName)) continue;
    bytes[offset + 4] = 0x1e;
    bytes[offset + 5] = 0x03;
    bytes[offset + 38] = 0x00;
    bytes[offset + 39] = 0x00;
    bytes[offset + 40] = 0xff;
    bytes[offset + 41] = 0xa1;
    return bytes;
  }
  fail('central directory entry "$entryName" not found');
}

Uint8List _withCentralExtraField(
  Uint8List zip,
  String name, {
  required int headerId,
  required List<int> payload,
  bool zip64Sentinels = false,
}) {
  final start = _centralEntryOffset(zip, name);
  if (start == null) fail('central directory entry "$name" not found');
  final nameLength = zip[start + 28] | (zip[start + 29] << 8);
  final extraLength = zip[start + 30] | (zip[start + 31] << 8);
  final insertAt = start + 46 + nameLength + extraLength;
  final added = 4 + payload.length;
  final bytes = Uint8List(zip.length + added);
  bytes.setRange(0, insertAt, zip.sublist(0, insertAt));
  bytes.setRange(insertAt + added, bytes.length, zip.sublist(insertAt));
  bytes[start + 30] = (extraLength + added) & 0xff;
  bytes[start + 31] = ((extraLength + added) >> 8) & 0xff;
  bytes[insertAt] = headerId & 0xff;
  bytes[insertAt + 1] = (headerId >> 8) & 0xff;
  bytes[insertAt + 2] = payload.length & 0xff;
  bytes[insertAt + 3] = (payload.length >> 8) & 0xff;
  bytes.setRange(insertAt + 4, insertAt + added, payload);
  if (zip64Sentinels) {
    _writeUint32(bytes, start + 20, 0xffffffff);
    _writeUint32(bytes, start + 24, 0xffffffff);
  }
  final end = _endOfCentralDirectoryOffset(bytes);
  _writeUint32(bytes, end + 12, _uint32At(bytes, end + 12) + added);
  return bytes;
}

Uint8List _withZip64EntrySentinels(Uint8List zip, String name) {
  final start = _centralEntryOffset(zip, name);
  if (start == null) fail('central directory entry "$name" not found');
  final payload = Uint8List(16);
  _writeUint64(payload, 0, _uint32At(zip, start + 24));
  _writeUint64(payload, 8, _uint32At(zip, start + 20));
  return _withCentralExtraField(
    zip,
    name,
    headerId: 1,
    payload: payload,
    zip64Sentinels: true,
  );
}

Uint8List _withExtendedTimestampExtraField(Uint8List zip, String name) =>
    _withCentralExtraField(
      zip,
      name,
      headerId: 0x5455,
      payload: const [0x01, 0x00, 0x00, 0x00, 0x00],
    );

bool _mayRestrictPermissions() {
  if (Platform.isWindows) return false;
  final result = Process.runSync('id', ['-u']);
  return result.exitCode == 0 && result.stdout.toString().trim() != '0';
}

final class _ObservedState {
  _ObservedState(this.preferences, this.files);

  final Map<String, Object> preferences;
  final Map<String, String> files;
}

const Set<String> _linkFollowingOperations = {
  'canonicalPath',
  'linkTarget',
  'readBoundedText',
  'probeReadableFile',
};

final class _RecordingSkinFileAccess implements ManagedSkinFileAccess {
  _RecordingSkinFileAccess(this.inner);

  final ManagedSkinFileAccess inner;
  final List<String> calls = [];

  @override
  Future<List<String>> listSubdirectoryNames(String path) {
    calls.add('listSubdirectoryNames:$path');
    return inner.listSubdirectoryNames(path);
  }

  @override
  Future<FileSystemEntityType> entityType(
    String path, {
    bool followLinks = false,
  }) {
    calls.add('entityType:$path');
    return inner.entityType(path, followLinks: followLinks);
  }

  @override
  Future<String> linkTarget(String path) {
    calls.add('linkTarget:$path');
    return inner.linkTarget(path);
  }

  @override
  Future<String> canonicalPath(String path) {
    calls.add('canonicalPath:$path');
    return inner.canonicalPath(path);
  }

  @override
  Future<String> readBoundedText(String path, {required int maxBytes}) {
    calls.add('readBoundedText:$path');
    return inner.readBoundedText(path, maxBytes: maxBytes);
  }

  @override
  Future<void> probeReadableFile(String path) {
    calls.add('probeReadableFile:$path');
    return inner.probeReadableFile(path);
  }

  List<String> followedPaths(Iterable<String> paths) => [
    for (final call in calls)
      if (_linkFollowingOperations.contains(call.split(':').first) &&
          paths.any((path) => call.endsWith(':$path')))
        call,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingPreferences platform;
  late Directory workspace;
  late Directory webUiDir;
  late SettingsController settings;

  setUp(() {
    platform = _RecordingPreferences();
    SharedPreferencesAsyncPlatform.instance = platform;
    SharedPreferences.resetStatic();

    workspace = Directory.systemTemp.createTempSync('retention_source');
    webUiDir = Directory(p.join(workspace.path, 'web-ui'))..createSync();
    File(p.join(workspace.path, 'new-owner-reset-journal.json'))
        .writeAsStringSync('{"state":"resetting","stage":"deletion"}');
    File(p.join(workspace.path, 'streamline_bridge.sqlite'))
        .writeAsStringSync('sqlite-canary');
    platform.values[SettingsKeys.defaultSkinId.name] = _flatSkinId;
    platform.values[SettingsKeys.telemetryConsent.name] = true;

    settings = SettingsController(SharedPreferencesSettingsService());

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => workspace.path,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    SharedPreferencesAsyncPlatform.instance = null;
    SharedPreferences.resetStatic();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  WebUIStorage newStorage({
    AssetBundle? assets,
    ManagedSkinFileAccess? access,
  }) {
    final storage = WebUIStorage(
      settings,
      webUIDir: webUiDir,
      bundledSkinAssets: assets,
      skinFileAccess: access,
    );
    storage.debugInitWithWebUIDir(webUiDir);
    return storage;
  }

  Future<void> install(WebUIStorage storage, Uint8List zipBytes) async {
    final source = File(
      p.join(
        workspace.path,
        'source-${DateTime.now().microsecondsSinceEpoch}.zip',
      ),
    )..writeAsBytesSync(zipBytes);
    await storage.installFromPath(source.path);
    source.deleteSync();
  }

  Map<String, String> treeSnapshot() => {
    for (final entity in workspace.listSync(
      recursive: true,
      followLinks: false,
    ))
      p.relative(entity.path, from: workspace.path): entity is File
          ? base64Encode(entity.readAsBytesSync())
          : entity is Link
          ? 'link:${entity.targetSync()}'
          : 'directory',
  };

  _ObservedState observeState() =>
      _ObservedState(Map<String, Object>.of(platform.values), treeSnapshot());

  void expectNoStateChange(_ObservedState before) {
    expect(platform.values, before.preferences, reason: 'preferences changed');
    expect(platform.writes, isEmpty, reason: 'preferences were written');
    expect(treeSnapshot(), before.files, reason: 'files changed');
  }

  group('qualified clean bundled sources', () {
    test(
      'qualifies a flat bundled ZIP installed by the real installer',
      () async {
        final zip = _skinZip(
          id: _flatSkinId,
          files: {'assets/app.js': 'console.log("skin");'},
        );
        final storage = newStorage(
          assets: _bundle(
            sourceIds: [_flatSkinId],
            sources: {_flatSkinId: zip},
          ),
        );
        await install(storage, zip);
        final installed = storage.installedSkins.map((skin) => skin.id).toSet();
        final before = observeState();

        final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

        expect(result.status, CleanSkinSourceStatus.qualified);
        expect(result.isQualified, isTrue);
        expect(result.skinId, _flatSkinId);
        expect(result.bundledAssetKey, _sourceAssetKey(_flatSkinId));
        expect(result.selectionStatus, isNull);
        expect(
          storage.installedSkins.map((skin) => skin.id).toSet(),
          installed,
          reason: 'the query changed the owner skin registry',
        );
        expectNoStateChange(before);
      },
    );

    test('qualifies a bundled ZIP with one top-level folder installed by the real installer', () async {
      final zip = _skinZip(
        id: 'wrapped.skin',
        root: 'wrapped.skin-main',
        files: {'src/style.css': 'body {}'},
      );
      final storage = newStorage(
        assets: _bundle(sourceIds: ['wrapped'], sources: {'wrapped': zip}),
      );
      await install(storage, zip);
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(
        'wrapped.skin',
      );

      expect(result.status, CleanSkinSourceStatus.qualified);
      expect(result.skinId, 'wrapped.skin');
      expect(result.bundledAssetKey, _sourceAssetKey('wrapped'));
      expectNoStateChange(before);
    });

    test(
      'qualifies a bundled source through the production asset channel',
      () async {
        final zip = _skinZip(
          id: _flatSkinId,
          files: {'assets/app.js': 'console.log("skin");'},
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMessageHandler(
          'flutter/assets',
          _assetChannel({
            _manifestAssetKey: utf8.encode(jsonEncode([_flatSkinId])),
            _sourceAssetKey(_flatSkinId): zip,
          }),
        );
        addTearDown(() {
          messenger.setMockMessageHandler('flutter/assets', null);
          rootBundle.evict(_manifestAssetKey);
          rootBundle.evict(_sourceAssetKey(_flatSkinId));
        });
        final storage = newStorage();
        await install(storage, zip);
        final before = observeState();

        final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

        expect(result.status, CleanSkinSourceStatus.qualified);
        expect(result.skinId, _flatSkinId);
        expect(result.bundledAssetKey, _sourceAssetKey(_flatSkinId));
        expectNoStateChange(before);
      },
    );

    test(
      'qualifies the real bundled asset through the default asset bundle',
      () async {
        final zip = File(p.join('assets', 'bundled_skins', 'WorkFlow-Skin.zip'))
            .readAsBytesSync();
        final storage = newStorage();
        await install(storage, zip);

        final result = await storage.qualifyCleanBundledSkinSource(
          'workflow-skin',
        );

        expect(result.status, CleanSkinSourceStatus.qualified);
        expect(result.skinId, 'workflow-skin');
        expect(result.bundledAssetKey, _sourceAssetKey('WorkFlow-Skin'));
      },
      skip: _realBundledSkinAvailable
          ? null
          : 'local-only control: assets/bundled_skins is an ignored build '
                'output absent on a fresh checkout and stubbed by CI',
    );
  });

  group('modified installed packages', () {
    late Uint8List zip;
    late WebUIStorage storage;

    setUp(() async {
      zip = _skinZip(
        id: _flatSkinId,
        files: {'assets/app.js': 'console.log("skin");'},
      );
      storage = newStorage(
        assets: _bundle(sourceIds: [_flatSkinId], sources: {_flatSkinId: zip}),
      );
      await install(storage, zip);
    });

    test('rejects a modified installed file', () async {
      File(p.join(webUiDir.path, _flatSkinId, 'assets', 'app.js'))
          .writeAsStringSync('console.log("skan");');
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.packageContentMismatch);
      expect(result.skinId, isNull);
      expect(result.bundledAssetKey, isNull);
      expectNoStateChange(before);
    });

    test('rejects an extra personal file in the installed package', () async {
      File(p.join(webUiDir.path, _flatSkinId, 'skin-state.json'))
          .writeAsStringSync('{"factory":"personal-state"}');
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.packageContentMismatch);
      expectNoStateChange(before);
    });

    test('rejects a missing installed file', () async {
      File(p.join(webUiDir.path, _flatSkinId, 'assets', 'app.js')).deleteSync();
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.packageContentMismatch);
      expectNoStateChange(before);
    });

    test('rejects a linked file inside the installed package', () async {
      final target = File(p.join(workspace.path, 'outside.js'))
        ..writeAsStringSync('console.log("outside");');
      final appJs = File(p.join(webUiDir.path, _flatSkinId, 'assets', 'app.js'))
        ..deleteSync();
      Link(appJs.path).createSync(target.path);
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.installedPackageUnsafe);
      expectNoStateChange(before);
    });

    test('rejects an oversized installed file without reading it', () async {
      final target = File(
        p.join(webUiDir.path, _flatSkinId, 'assets', 'app.js'),
      );
      final handle = target.openSync(mode: FileMode.write);
      try {
        handle.setPositionSync(17 * 1024 * 1024);
        handle.writeByteSync(0x41);
      } finally {
        handle.closeSync();
      }
      expect(target.lengthSync(), greaterThan(16 * 1024 * 1024));

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.installedPackageUnsafe);
    });

    test(
      'rejects an unreadable installed file',
      () async {
        final target = File(
          p.join(webUiDir.path, _flatSkinId, 'assets', 'app.js'),
        );
        Process.runSync('chmod', ['000', target.path]);
        try {
          final result = await storage.qualifyCleanBundledSkinSource(
            _flatSkinId,
          );

          expect(
            result.status,
            CleanSkinSourceStatus.installedPackageUnreadable,
          );
        } finally {
          Process.runSync('chmod', ['644', target.path]);
        }
      },
      skip: _mayRestrictPermissions() ? null : 'requires a non-root POSIX user',
    );
  });

  group('contained links in the selected package', () {
    late Uint8List zip;
    late _RecordingSkinFileAccess access;
    late WebUIStorage storage;
    late String packagePath;

    setUp(() async {
      zip = _skinZip(
        id: _flatSkinId,
        files: {'assets/app.js': 'console.log("skin");'},
      );
      access = _RecordingSkinFileAccess(const SystemManagedSkinFileAccess());
      storage = newStorage(
        assets: _bundle(sourceIds: [_flatSkinId], sources: {_flatSkinId: zip}),
        access: access,
      );
      await install(storage, zip);
      packagePath = p.join(webUiDir.path, _flatSkinId);
    });

    test('rejects a skin manifest link without following it', () async {
      final manifest = File(p.join(packagePath, 'skin-manifest.json'));
      final target = File(p.join(packagePath, 'manifest-real.json'))
        ..writeAsStringSync(manifest.readAsStringSync());
      manifest.deleteSync();
      Link(manifest.path).createSync(target.path);
      access.calls.clear();
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.skinSelectionRejected);
      expect(result.selectionStatus, ManagedSkinLookupStatus.unreadable);
      expect(
        access.followedPaths([manifest.path, target.path]),
        isEmpty,
        reason: 'the query followed a contained manifest link',
      );
      expectNoStateChange(before);
    });

    test('rejects an entrypoint link without following it', () async {
      final index = File(p.join(packagePath, 'index.html'));
      final target = File(p.join(packagePath, 'index-real.html'))
        ..writeAsStringSync(index.readAsStringSync());
      index.deleteSync();
      Link(index.path).createSync(target.path);
      access.calls.clear();
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.skinSelectionRejected);
      expect(result.selectionStatus, ManagedSkinLookupStatus.unreadable);
      expect(
        access.followedPaths([index.path, target.path]),
        isEmpty,
        reason: 'the query followed a contained entrypoint link',
      );
      expectNoStateChange(before);
    });
  });

  group('bundled source selection', () {
    late Uint8List zip;

    setUp(() async {
      zip = _skinZip(id: _flatSkinId);
    });

    test('rejects an installed skin with no bundled source', () async {
      final custom = _skinZip(
        id: 'custom.skin',
        files: {'mine.txt': 'personal'},
      );
      final storage = newStorage(
        assets: _bundle(sourceIds: [_flatSkinId], sources: {_flatSkinId: zip}),
      );
      await install(storage, custom);
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource('custom.skin');

      expect(result.status, CleanSkinSourceStatus.bundledSourceAbsent);
      expect(result.skinId, isNull);
      expectNoStateChange(before);
    });

    test('rejects two bundled sources declaring the same skin id', () async {
      final duplicate = _skinZip(
        id: _flatSkinId,
        files: {'other.txt': 'second source'},
      );
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId, 'second'],
          sources: {_flatSkinId: zip, 'second': duplicate},
        ),
      );
      await install(storage, zip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceAmbiguous);
    });

    test('rejects a bundled source the asset bundle cannot read', () async {
      final storage = newStorage(assets: _bundle(sourceIds: [_flatSkinId]));
      await install(storage, zip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnreadable);
    });

    test('rejects a corrupt bundled source', () async {
      final truncated = Uint8List.sublistView(
        zip,
        0,
        (zip.length * 0.6).round(),
      );
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: truncated},
        ),
      );
      await install(storage, zip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test('rejects a bundled source with ambiguous manifest names', () async {
      final ambiguous = _skinZip(
        id: _flatSkinId,
        extraEntries: [
          ArchiveFile.string(
            'manifest.json',
            jsonEncode({'id': _flatSkinId, 'name': _flatSkinId}),
          ),
        ],
      );
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: ambiguous},
        ),
      );
      await install(storage, zip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnreadable);
    });

    test('rejects an unavailable bundled manifest', () async {
      final missing = newStorage(assets: _MapAssetBundle(const {}));
      await install(missing, zip);
      expect(
        (await missing.qualifyCleanBundledSkinSource(_flatSkinId)).status,
        CleanSkinSourceStatus.bundledManifestUnavailable,
      );

      final malformed = newStorage(
        assets: _bundle(
          sourceIds: const [],
          sources: {_flatSkinId: zip},
          manifestBytes: Uint8List.fromList(utf8.encode('{"not":"a list"}')),
        ),
      );
      expect(
        (await malformed.qualifyCleanBundledSkinSource(_flatSkinId)).status,
        CleanSkinSourceStatus.bundledManifestUnavailable,
      );

      final duplicated = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId, _flatSkinId],
          sources: {_flatSkinId: zip},
        ),
      );
      expect(
        (await duplicated.qualifyCleanBundledSkinSource(_flatSkinId)).status,
        CleanSkinSourceStatus.bundledManifestUnavailable,
      );
    });

    test('rejects a bundled manifest with too many sources', () async {
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [for (var index = 0; index < 65; index++) 'source$index'],
        ),
      );
      await install(storage, zip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledManifestUnavailable);
    });
  });

  group('unsafe bundled archive layouts', () {
    late WebUIStorage storage;

    Future<void> installFlat(WebUIStorage target) =>
        install(target, _skinZip(id: _flatSkinId));

    test('rejects unsafe archive entry paths', () async {
      final unsafeNames = {
        '../escape.js',
        '/absolute.js',
        'nested\\backslash.js',
        'C:/drive.js',
        'trailing-space ',
        'dotted.',
        'CON',
        'caf\u00e9.js',
        'nul\u0000byte.js',
        'nested/${List.filled(33, 'deep').join('/')}.js',
        'long/${List.filled(17, 'a' * 64).join('/')}.js',
      };
      for (final unsafeName in unsafeNames) {
        final unsafeZip = _skinZip(
          id: _flatSkinId,
          extraEntries: [ArchiveFile.string(unsafeName, 'content')],
        );
        storage = newStorage(
          assets: _bundle(
            sourceIds: [_flatSkinId],
            sources: {_flatSkinId: unsafeZip},
          ),
        );
        await installFlat(storage);

        final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

        expect(
          result.status,
          CleanSkinSourceStatus.bundledSourceUnsafe,
          reason: 'accepted unsafe archive entry "$unsafeName"',
        );
      }
    });

    test('rejects an archive entry whose name ends in a backslash', () async {
      final backslash = _skinZip(
        id: _flatSkinId,
        extraEntries: [ArchiveFile.string('empty\\', '')],
      );
      storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: backslash},
        ),
      );
      await installFlat(storage);
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
      expect(result.skinId, isNull);
      expect(result.bundledAssetKey, isNull);
      expectNoStateChange(before);
    });

    test(
      'rejects duplicate, case-colliding and prefix-colliding entries',
      () async {
        Uint8List collisionZip(List<ArchiveFile> entries) =>
            Uint8List.fromList(ZipEncoder().encode(_EntryListArchive(entries)));
        List<ArchiveFile> baseEntries() => [
          ArchiveFile.string(
            'skin-manifest.json',
            jsonEncode({'id': _flatSkinId, 'name': _flatSkinId}),
          ),
          ArchiveFile.string('index.html', '<html>skin</html>'),
          ArchiveFile.string('assets/app.js', 'console.log("skin");'),
        ];

        final collisions = <String, Uint8List>{
          'duplicate': collisionZip([
            ...baseEntries(),
            ArchiveFile.string('assets/app.js', 'console.log("skin");'),
          ]),
          'case': collisionZip([
            ...baseEntries(),
            ArchiveFile.string('assets/App.js', 'console.log("skin");'),
          ]),
          'prefix': collisionZip([
            ...baseEntries(),
            ArchiveFile.string('assets', 'folder-like file'),
          ]),
        };
        for (final collision in collisions.entries) {
          storage = newStorage(
            assets: _bundle(
              sourceIds: [_flatSkinId],
              sources: {_flatSkinId: collision.value},
            ),
          );
          await installFlat(storage);

          final result = await storage.qualifyCleanBundledSkinSource(
            _flatSkinId,
          );

          expect(
            result.status,
            CleanSkinSourceStatus.bundledSourceUnsafe,
            reason: 'accepted a ${collision.key} archive entry collision',
          );
        }
      },
    );

    test('rejects a symbolic link entry', () async {
      final linked = _withUnixSymlinkEntry(
        _skinZip(
          id: _flatSkinId,
          extraEntries: [ArchiveFile.string('linked.js', '/etc/passwd')],
        ),
        'linked.js',
      );
      storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: linked},
        ),
      );
      await installFlat(storage);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test('rejects an archive with an empty entrypoint', () async {
      final empty = _skinZip(id: _flatSkinId, indexHtml: '');
      storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: empty},
        ),
      );
      await installFlat(storage);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test('rejects an archive with too many entries', () async {
      final crowded = _skinZip(
        id: _flatSkinId,
        extraEntries: [
          for (var index = 0; index < 4096; index++)
            ArchiveFile.string('assets/file$index.js', ''),
        ],
      );
      storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: crowded},
        ),
      );
      await installFlat(storage);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test('rejects an oversized archive file before decompression', () async {
      final oversized = _skinZip(
        id: _flatSkinId,
        extraEntries: [
          ArchiveFile.string('assets/big.bin', 'a' * (17 * 1024 * 1024)),
        ],
      );
      expect(oversized.length, lessThan(32 * 1024 * 1024));
      storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: oversized},
        ),
      );
      await installFlat(storage);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test('rejects an archive above the compressed source budget', () async {
      storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: Uint8List(32 * 1024 * 1024 + 1)},
        ),
      );
      await installFlat(storage);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test('rejects an archive above the total uncompressed budget', () async {
      final padding = <String, String>{
        for (var index = 0; index < 5; index++)
          'assets/padding$index.bin': 'a' * (13 * 1024 * 1024),
      };
      final padded = _skinZip(id: _flatSkinId, files: padding);
      expect(padded.length, lessThan(32 * 1024 * 1024));
      storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: padded},
        ),
      );
      await installFlat(storage);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });
  });

  group('managed selection refusals', () {
    test('rejects an invalid skin id', () async {
      final storage = newStorage(assets: _bundle(sourceIds: [_flatSkinId]));

      final result = await storage.qualifyCleanBundledSkinSource('../escape');

      expect(result.status, CleanSkinSourceStatus.invalidSkinId);
      expect(result.selectionStatus, isNull);
    });

    test('preserves the owner selection refusals', () async {
      final zip = _skinZip(id: _flatSkinId);
      final storage = newStorage(
        assets: _bundle(sourceIds: [_flatSkinId], sources: {_flatSkinId: zip}),
      );
      await install(storage, zip);
      final outside = Directory(p.join(workspace.path, 'outside'))
        ..createSync();
      File(p.join(outside.path, 'index.html'))
          .writeAsStringSync('<html></html>');

      final missing = await storage.qualifyCleanBundledSkinSource(
        'absent.skin',
      );
      final escaped = await storage.qualifyCleanBundledSkinSource(
        _flatSkinId,
        runtimePath: outside.path,
      );

      expect(missing.status, CleanSkinSourceStatus.skinSelectionRejected);
      expect(missing.selectionStatus, ManagedSkinLookupStatus.missing);
      expect(escaped.status, CleanSkinSourceStatus.skinSelectionRejected);
      expect(escaped.selectionStatus, ManagedSkinLookupStatus.escaped);
    });
  });

  group('runtime skin path selection', () {
    test('rejects a sibling runtime alias before following it', () async {
      final zip = _skinZip(
        id: _flatSkinId,
        files: {'assets/app.js': 'console.log("skin");'},
      );
      final access = _RecordingSkinFileAccess(
        const SystemManagedSkinFileAccess(),
      );
      final storage = newStorage(
        assets: _bundle(sourceIds: [_flatSkinId], sources: {_flatSkinId: zip}),
        access: access,
      );
      await install(storage, zip);
      final packagePath = p.join(webUiDir.path, _flatSkinId);
      final aliasPath = p.join(webUiDir.path, 'alias.skin');
      Link(aliasPath).createSync(_flatSkinId);
      access.calls.clear();
      final before = observeState();

      final alias = await storage.qualifyCleanBundledSkinSource(
        _flatSkinId,
        runtimePath: aliasPath,
      );
      final aliasCalls = List<String>.of(access.calls);
      access.calls.clear();
      final selected = await storage.qualifyCleanBundledSkinSource(
        _flatSkinId,
        runtimePath: packagePath,
      );

      expect(alias.status, CleanSkinSourceStatus.skinSelectionRejected);
      expect(alias.selectionStatus, ManagedSkinLookupStatus.ambiguous);
      expect(alias.skinId, isNull);
      expect(alias.bundledAssetKey, isNull);
      expect(
        aliasCalls.where(
          (call) =>
              _linkFollowingOperations.contains(call.split(':').first) &&
              call.contains('alias.skin'),
        ),
        isEmpty,
        reason: 'the runtime alias was followed instead of rejected',
      );
      expect(
        aliasCalls,
        contains('canonicalPath:$packagePath'),
        reason: 'the selected package must still be resolved',
      );
      expect(selected.status, CleanSkinSourceStatus.qualified);
      expect(selected.skinId, _flatSkinId);
      expect(selected.bundledAssetKey, _sourceAssetKey(_flatSkinId));
      expectNoStateChange(before);
    });
  });

  group('read-only observation', () {
    test('leaves unrelated files and preferences untouched', () async {
      final zip = _skinZip(
        id: _flatSkinId,
        files: {'assets/app.js': 'console.log("skin");'},
      );
      final storage = newStorage(
        assets: _bundle(sourceIds: [_flatSkinId], sources: {_flatSkinId: zip}),
      );
      await install(storage, zip);
      await install(storage, _skinZip(id: 'other.skin', files: {'a.txt': 'b'}));
      File(p.join(webUiDir.path, 'other.skin', 'personal.json'))
          .writeAsStringSync('{"state":"kept"}');
      final before = observeState();

      final qualified = await storage.qualifyCleanBundledSkinSource(
        _flatSkinId,
      );
      final absent = await storage.qualifyCleanBundledSkinSource('other.skin');

      expect(qualified.status, CleanSkinSourceStatus.qualified);
      expect(absent.status, CleanSkinSourceStatus.bundledSourceAbsent);
      expectNoStateChange(before);
      expect(
        File(p.join(webUiDir.path, 'other.skin', 'personal.json'))
            .readAsStringSync(),
        '{"state":"kept"}',
      );
    });
  });

  group('bounded decompression', () {
    late Uint8List installedZip;

    setUp(() {
      installedZip = _skinZip(
        id: _flatSkinId,
        files: {'assets/app.js': 'A' * 64},
      );
    });

    test('stops a lying header during inflation', () async {
      final lying = _patchCentralEntry(
        _skinZip(
          id: _flatSkinId,
          files: {'assets/app.js': 'A' * (4 * 1024 * 1024)},
        ),
        'assets/app.js',
        uncompressedSize: 64,
      );
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: lying},
        ),
      );
      await install(storage, installedZip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
      expect(
        WebUIStorage.debugCleanSkinInflationBytesWritten,
        64,
        reason: 'decompression was not bounded at the declared size',
      );
    });

    test('rejects a decoder failure as a typed rejection', () async {
      final corrupt = _corruptEntryPayload(
        _skinZip(
          id: _flatSkinId,
          files: {'assets/app.js': 'console.log("skin");'},
        ),
        'assets/app.js',
      );
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: corrupt},
        ),
      );
      await install(
        storage,
        _skinZip(
          id: _flatSkinId,
          files: {'assets/app.js': 'console.log("skin");'},
        ),
      );

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
      expect(result.skinId, isNull);
      expect(result.bundledAssetKey, isNull);
    });

    test('rejects a stored entry with a mismatched checksum', () async {
      final zip = _skinZip(
        id: _flatSkinId,
        files: {'assets/app.js': 'console.log("skin");'},
        compression: CompressionType.none,
      );
      final wrongCrc = _centralCrc(zip, 'assets/app.js') ^ 0xff;
      final corruptCrc = _patchCentralEntry(
        _patchLocalHeader(zip, 'assets/app.js', crc32: wrongCrc),
        'assets/app.js',
        crc32: wrongCrc,
      );
      expect(_centralCrc(corruptCrc, 'assets/app.js'), wrongCrc);
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: corruptCrc},
        ),
      );
      await install(
        storage,
        _skinZip(
          id: _flatSkinId,
          files: {'assets/app.js': 'console.log("skin");'},
        ),
      );

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test('rejects a stored entry whose recorded size disagrees', () async {
      final zip = _skinZip(
        id: _flatSkinId,
        files: {'assets/app.js': 'console.log("skin");'},
        compression: CompressionType.none,
      );
      final inconsistent = _patchCentralEntry(
        zip,
        'assets/app.js',
        uncompressedSize: 4096,
      );
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: inconsistent},
        ),
      );
      await install(
        storage,
        _skinZip(id: _flatSkinId, files: {'assets/app.js': 'A' * 4096}),
      );

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test('rejects an unsupported compression method', () async {
      final zip = _skinZip(id: _flatSkinId);
      final unsupported = _patchCentralEntry(
        zip,
        'index.html',
        compressionMethod: 12,
      );
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: unsupported},
        ),
      );
      await install(storage, zip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test('qualifies stored and deflated entries', () async {
      final zip = _skinZip(
        id: _flatSkinId,
        files: {'assets/app.js': 'console.log("skin");'},
        compression: CompressionType.none,
      );
      final storage = newStorage(
        assets: _bundle(sourceIds: [_flatSkinId], sources: {_flatSkinId: zip}),
      );
      await install(storage, zip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.qualified);
      expect(result.bundledAssetKey, _sourceAssetKey(_flatSkinId));
    });
  });

  group('strict archive decoding', () {
    late Uint8List zip;

    setUp(() {
      zip = _skinZip(
        id: _flatSkinId,
        files: {'assets/app.js': 'console.log("skin");'},
      );
    });

    Future<CleanSkinSourceStatus> qualifyWith(Uint8List source) async {
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: source},
        ),
      );
      await install(storage, zip);
      return (await storage.qualifyCleanBundledSkinSource(_flatSkinId)).status;
    }

    test('rejects a non-final deflate stream', () async {
      expect(
        await qualifyWith(_clearDeflateFinalFlag(zip, 'index.html')),
        CleanSkinSourceStatus.bundledSourceUnsafe,
      );
    });

    test('rejects a truncated deflate stream', () async {
      final compressed = _centralCompressedSize(zip, 'index.html');

      expect(
        await qualifyWith(
          _patchCentralEntry(zip, 'index.html', compressedSize: compressed - 2),
        ),
        CleanSkinSourceStatus.bundledSourceUnsafe,
      );
    });

    test('rejects trailing bytes after a deflate stream', () async {
      final compressed = _centralCompressedSize(zip, 'index.html');

      expect(
        await qualifyWith(
          _patchCentralEntry(zip, 'index.html', compressedSize: compressed + 2),
        ),
        CleanSkinSourceStatus.bundledSourceUnsafe,
      );
    });

    test('rejects a local header name that disagrees', () async {
      expect(
        await qualifyWith(
          _patchLocalHeader(zip, 'index.html', filename: 'index.htmX'),
        ),
        CleanSkinSourceStatus.bundledSourceUnsafe,
      );
    });

    test(
      'rejects a local encryption flag with a clean central directory',
      () async {
        expect(
          await qualifyWith(_patchLocalHeader(zip, 'index.html', flags: 0x1)),
          CleanSkinSourceStatus.bundledSourceUnsafe,
        );
      },
    );

    test('rejects a local data-descriptor flag that disagrees', () async {
      expect(
        await qualifyWith(_patchLocalHeader(zip, 'index.html', flags: 0x8)),
        CleanSkinSourceStatus.bundledSourceUnsafe,
      );
    });

    test(
      'rejects a central directory count that disagrees with its records',
      () async {
        expect(
          await qualifyWith(_patchEndOfCentralDirectoryCount(zip, 1)),
          CleanSkinSourceStatus.bundledSourceUnsafe,
        );
      },
    );

    test('rejects a ZIP64 alternate central directory', () async {
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: _zip64AlternateCentralDirectory(zip)},
        ),
      );
      await install(storage, zip);
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
      expect(result.skinId, isNull);
      expect(result.bundledAssetKey, isNull);
      expect(
        WebUIStorage.debugCleanSkinParseBytesRead,
        isNull,
        reason: 'the alternate central directory must not be parsed',
      );
      expectNoStateChange(before);
    });

    test('rejects a central record with ZIP64 sentinel fields', () async {
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {
            _flatSkinId: _withZip64EntrySentinels(zip, 'assets/app.js'),
          },
        ),
      );
      await install(storage, zip);
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
      expect(result.skinId, isNull);
      expect(result.bundledAssetKey, isNull);
      expect(
        WebUIStorage.debugCleanSkinParseBytesRead,
        isNull,
        reason: 'the compressed size must not be resolved from a ZIP64 extra',
      );
      expectNoStateChange(before);
    });

    test('accepts a central record with a non-ZIP64 extra field', () async {
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {
            _flatSkinId: _withExtendedTimestampExtraField(zip, 'assets/app.js'),
          },
        ),
      );
      await install(storage, zip);
      final before = observeState();

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.qualified);
      expect(result.skinId, _flatSkinId);
      expect(result.bundledAssetKey, _sourceAssetKey(_flatSkinId));
      expectNoStateChange(before);
    });

    test(
      'rejects an earlier end record the archive parser can select',
      () async {
        final storage = newStorage(
          assets: _bundle(
            sourceIds: [_flatSkinId],
            sources: {_flatSkinId: _zip64ChunkBoundaryArchive(zip)},
          ),
        );
        await install(storage, zip);
        final before = observeState();

        final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

        expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
        expect(result.skinId, isNull);
        expect(result.bundledAssetKey, isNull);
        expect(
          WebUIStorage.debugCleanSkinParseBytesRead,
          isNull,
          reason: 'the central directory must not be parsed',
        );
        expectNoStateChange(before);
      },
    );

    test('bounds the archive metadata parse reads', () async {
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: _sharedLocalHeaderArchive()},
        ),
      );
      await install(storage, zip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
      expect(
        WebUIStorage.debugCleanSkinParseBytesRead,
        lessThanOrEqualTo(128 * 1024 * 1024 + 64 * 1024),
        reason: 'metadata parse reads must stop at the parse budget',
      );
    });

    test('qualifies a deflate source within the parse budget', () async {
      final storage = newStorage(
        assets: _bundle(sourceIds: [_flatSkinId], sources: {_flatSkinId: zip}),
      );
      await install(storage, zip);

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.qualified);
      final reads = WebUIStorage.debugCleanSkinParseBytesRead;
      expect(reads, isNotNull);
      expect(reads, greaterThan(0));
      expect(reads, lessThan(1024 * 1024));
    });
  });

  group('competing bundled sources', () {
    late Uint8List selectedZip;

    setUp(() async {
      selectedZip = _skinZip(id: _flatSkinId);
    });

    Future<CleanSkinSourceQualification> qualify({
      Map<String, Uint8List> sources = const {},
    }) async {
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId, 'unknown'],
          sources: {_flatSkinId: selectedZip, ...sources},
        ),
      );
      await install(storage, selectedZip);
      return storage.qualifyCleanBundledSkinSource(_flatSkinId);
    }

    test('an unreadable competing source cannot be ignored', () async {
      final result = await qualify();

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnreadable);
      expect(result.isQualified, isFalse);
    });

    test('a corrupt competing source cannot be ignored', () async {
      final result = await qualify(
        sources: {'unknown': Uint8List.fromList(utf8.encode('not a zip'))},
      );

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
      expect(result.isQualified, isFalse);
    });

    test(
      'a competing source with malformed metadata cannot be ignored',
      () async {
        final result = await qualify(
          sources: {
            'unknown': _corruptEntryPayload(
              _skinZip(id: 'other.skin'),
              'skin-manifest.json',
            ),
          },
        );

        expect(result.status, CleanSkinSourceStatus.bundledSourceUnreadable);
        expect(result.isQualified, isFalse);
      },
    );

    test('a competing source with a different identity is ignored', () async {
      final result = await qualify(
        sources: {'unknown': _skinZip(id: 'other.skin')},
      );

      expect(result.status, CleanSkinSourceStatus.qualified);
      expect(result.bundledAssetKey, _sourceAssetKey(_flatSkinId));
    });
  });

  group('bounded installed traversal', () {
    test(
      'bounds the visited installed entries including directories',
      () async {
        final zip = _skinZip(id: _flatSkinId);
        final storage = newStorage(
          assets: _bundle(
            sourceIds: [_flatSkinId],
            sources: {_flatSkinId: zip},
          ),
        );
        await install(storage, zip);
        for (var index = 0; index < 4097; index++) {
          Directory(p.join(webUiDir.path, _flatSkinId, 'empty$index'))
              .createSync();
        }
        final before = observeState();

        final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

        expect(result.status, CleanSkinSourceStatus.installedPackageUnsafe);
        expectNoStateChange(before);
      },
    );
  });

  group('case-folded directory prefixes', () {
    test('rejects archive paths that collide only by prefix case', () async {
      final colliding = _skinZip(
        id: _flatSkinId,
        files: {'Assets/a.js': 'console.log("a");', 'assets/b.js': 'b'},
      );
      final storage = newStorage(
        assets: _bundle(
          sourceIds: [_flatSkinId],
          sources: {_flatSkinId: colliding},
        ),
      );
      await install(storage, _skinZip(id: _flatSkinId));

      final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

      expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
    });

    test(
      'rejects an archive file that collides with a directory prefix path',
      () async {
        final colliding = _skinZip(
          id: _flatSkinId,
          extraEntries: [
            ArchiveFile.string('ASSETS', 'folder-like file'),
            ArchiveFile.string('assets/a.js', 'console.log("a");'),
          ],
        );
        final storage = newStorage(
          assets: _bundle(
            sourceIds: [_flatSkinId],
            sources: {_flatSkinId: colliding},
          ),
        );
        await install(storage, _skinZip(id: _flatSkinId));

        final result = await storage.qualifyCleanBundledSkinSource(_flatSkinId);

        expect(result.status, CleanSkinSourceStatus.bundledSourceUnsafe);
      },
    );
  });
}
