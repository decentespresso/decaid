import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';

class ZipWriteException implements Exception {
  final String message;
  const ZipWriteException(this.message);

  @override
  String toString() => 'ZipWriteException: $message';
}

class StreamingZipWriter {
  final File _file;
  final RandomAccessFile _raf;
  final DataTransferLimits _limits;

  int _offset = 0;
  int _entryCount = 0;
  int _totalUncompressed = 0;
  bool _closed = false;
  bool _aborted = false;

  final List<_CdEntry> _centralDirectory = [];

  StreamingZipWriter._(this._file, this._raf, this._limits);

  static Future<StreamingZipWriter> create(
    Directory tempDir,
    DataTransferLimits limits,
  ) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}export.zip');
    final raf = await file.open(mode: FileMode.write);
    return StreamingZipWriter._(file, raf, limits);
  }

  File get file => _file;

  ZipEntrySink addEntry(String name) {
    if (_closed || _aborted) {
      throw const ZipWriteException('The ZIP writer is already closed.');
    }
    final nameBytes = Uint8List.fromList(utf8.encode(name));
    if (nameBytes.length > _limits.maxFilenameBytes) {
      throw ZipWriteException('ZIP entry name is too long: $name');
    }
    if (_entryCount >= _limits.maxEntryCount) {
      throw const ZipWriteException('Too many ZIP entries.');
    }

    final localHeaderOffset = _offset;
    final headerLen = 30 + nameBytes.length;
    if (_offset + headerLen > DataTransferLimits.maxZip32) {
      throw const ZipWriteException(
        'Export exceeds the 4 GiB ZIP limit; use selected-section export.',
      );
    }

    final now = DateTime.now();
    final time = _dosTime(now);
    final date = _dosDate(now);
    final buf = BytesBuilder(copy: false);
    _writeUint32(buf, 0x04034b50);
    _writeUint16(buf, 20);
    _writeUint16(buf, 0x0808);
    _writeUint16(buf, 8);
    _writeUint16(buf, time);
    _writeUint16(buf, date);
    _writeUint32(buf, 0);
    _writeUint32(buf, 0);
    _writeUint32(buf, 0);
    _writeUint16(buf, nameBytes.length);
    _writeUint16(buf, 0);
    buf.add(nameBytes);
    _raf.writeFromSync(buf.takeBytes());
    _offset += headerLen;

    final entry = _EntryState(localHeaderOffset, nameBytes, time, date);
    _entryCount++;
    return ZipEntrySink._(this, entry);
  }

  Future<void> close() async {
    if (_closed || _aborted) return;
    _closed = true;

    final cdOffset = _offset;
    final cd = BytesBuilder(copy: false);
    for (final entry in _centralDirectory) {
      _writeCdEntry(cd, entry);
    }
    final cdBytes = cd.takeBytes();
    if (_offset + cdBytes.length > DataTransferLimits.maxZip32) {
      throw const ZipWriteException(
        'Export exceeds the 4 GiB ZIP limit; use selected-section export.',
      );
    }
    if (_offset + cdBytes.length + 22 > _limits.maxImportRequestBytes) {
      throw const ZipWriteException(
        'Export exceeds the import size limit; use selected-section export.',
      );
    }
    _raf.writeFromSync(cdBytes);
    _offset += cdBytes.length;

    final eocd = BytesBuilder(copy: false);
    _writeUint32(eocd, 0x06054b50);
    _writeUint16(eocd, 0);
    _writeUint16(eocd, 0);
    _writeUint16(eocd, _entryCount);
    _writeUint16(eocd, _entryCount);
    _writeUint32(eocd, cdBytes.length);
    _writeUint32(eocd, cdOffset);
    _writeUint16(eocd, 0);
    _raf.writeFromSync(eocd.takeBytes());

    await _raf.close();
  }

  Future<void> abort() async {
    if (_aborted) return;
    _aborted = true;
    _closed = true;
    try {
      await _raf.close();
    } catch (_) {}
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }

  void _registerEntry(_EntryState entry, {required int compressedSize}) {
    entry.compressedSize = compressedSize;
    _centralDirectory.add(
      _CdEntry(
        name: entry.nameBytes,
        localHeaderOffset: entry.localHeaderOffset,
        crc32: entry.crc32,
        compressedSize: compressedSize,
        uncompressedSize: entry.uncompressedSize,
        time: entry.time,
        date: entry.date,
      ),
    );
  }

  void _writeCdEntry(BytesBuilder out, _CdEntry e) {
    _writeUint32(out, 0x02014b50);
    _writeUint16(out, 0x031E);
    _writeUint16(out, 20);
    _writeUint16(out, 0x0808);
    _writeUint16(out, 8);
    _writeUint16(out, e.time);
    _writeUint16(out, e.date);
    _writeUint32(out, e.crc32);
    _writeUint32(out, e.compressedSize);
    _writeUint32(out, e.uncompressedSize);
    _writeUint16(out, e.name.length);
    _writeUint16(out, 0);
    _writeUint16(out, 0);
    _writeUint16(out, 0);
    _writeUint16(out, 0);
    _writeUint32(out, 0);
    _writeUint32(out, e.localHeaderOffset);
    out.add(e.name);
  }

  int get _currentOffset => _offset;

  void _writeBytes(Uint8List bytes) {
    _raf.writeFromSync(bytes);
    _offset += bytes.length;
  }

  void _writeDescriptor(_EntryState entry) {
    final buf = BytesBuilder(copy: false);
    _writeUint32(buf, 0x08074b50);
    _writeUint32(buf, entry.crc32);
    _writeUint32(buf, entry.compressedSize);
    _writeUint32(buf, entry.uncompressedSize);
    _writeBytes(buf.takeBytes());
  }

  static void _writeUint16(BytesBuilder b, int value) {
    b.addByte(value & 0xFF);
    b.addByte((value >> 8) & 0xFF);
  }

  static void _writeUint32(BytesBuilder b, int value) {
    b.addByte(value & 0xFF);
    b.addByte((value >> 8) & 0xFF);
    b.addByte((value >> 16) & 0xFF);
    b.addByte((value >> 24) & 0xFF);
  }

  static int _dosTime(DateTime dt) =>
      ((dt.hour & 0x1F) << 11) |
      ((dt.minute & 0x3F) << 5) |
      ((dt.second ~/ 2) & 0x1F);

  static int _dosDate(DateTime dt) =>
      (((dt.year - 1980) & 0x7F) << 9) |
      ((dt.month & 0x0F) << 5) |
      (dt.day & 0x1F);
}

class _EntryState {
  final int localHeaderOffset;
  final Uint8List nameBytes;
  final int time;
  final int date;

  int crc32 = 0;
  int uncompressedSize = 0;
  int compressedSize = 0;

  _EntryState(this.localHeaderOffset, this.nameBytes, this.time, this.date);
}

class _CdEntry {
  final Uint8List name;
  final int localHeaderOffset;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int time;
  final int date;

  _CdEntry({
    required this.name,
    required this.localHeaderOffset,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.time,
    required this.date,
  });
}

class ZipEntrySink {
  final StreamingZipWriter _writer;
  final _EntryState _entry;

  late final _DeflateFileSink _deflateSink;
  late final ByteConversionSink _inSink;

  bool _closed = false;

  ZipEntrySink._(StreamingZipWriter writer, _EntryState entry)
    : _writer = writer,
      _entry = entry {
    final encoder = ZLibCodec(raw: true, level: 6).encoder;
    _deflateSink = _DeflateFileSink(
      writer,
      entry,
      onFinish: () {
        _writer._registerEntry(entry, compressedSize: entry.compressedSize);
        _writer._writeDescriptor(entry);
      },
    );
    _inSink = encoder.startChunkedConversion(_deflateSink);
  }

  void write(Uint8List bytes) {
    if (_closed) {
      throw const ZipWriteException('The ZIP entry is already closed.');
    }
    _entry.uncompressedSize += bytes.length;
    if (_entry.uncompressedSize > _writer._limits.maxEntryUncompressedBytes) {
      throw const ZipWriteException('ZIP entry exceeds the size limit.');
    }
    _writer._totalUncompressed += bytes.length;
    if (_writer._totalUncompressed >
        _writer._limits.maxTotalUncompressedBytes) {
      throw const ZipWriteException(
        'Export exceeds the total uncompressed size limit.',
      );
    }
    _entry.crc32 = getCrc32(bytes, _entry.crc32);
    _inSink.add(bytes);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _inSink.close();
  }
}

class _DeflateFileSink implements Sink<List<int>> {
  final StreamingZipWriter _writer;
  final _EntryState _entry;
  final void Function() onFinish;

  _DeflateFileSink(this._writer, this._entry, {required this.onFinish});

  @override
  void add(List<int> chunk) {
    _entry.compressedSize += chunk.length;
    if (_writer._currentOffset + chunk.length > DataTransferLimits.maxZip32) {
      throw const ZipWriteException(
        'Export exceeds the 4 GiB ZIP limit; use selected-section export.',
      );
    }
    _writer._writeBytes(Uint8List.fromList(chunk));
  }

  @override
  void close() {
    onFinish();
  }
}
