import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/services/webserver/data_export/streaming_zip_reader.dart';
import 'package:reaprime/src/services/webserver/data_export/streaming_zip_writer.dart';

/// Builds a ZIP with the given files using the old in-memory ZipEncoder (the
/// previous decoder path's producer, no data descriptors).
List<int> buildLegacyZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  return ZipEncoder().encode(archive);
}

Future<StreamingZipWriter> writeZip(
  Directory dir, {
  DataTransferLimits? limits,
  void Function(StreamingZipWriter w)? writer,
}) async {
  final w = await StreamingZipWriter.create(
    dir,
    limits ?? const DataTransferLimits(),
  );
  writer?.call(w);
  return w;
}

String decode(List<int> bytes) => utf8.decode(bytes);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zip-test-');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('StreamingZipWriter', () {
    test('writes a ZIP readable by the archive ZipDecoder', () async {
      final w = await StreamingZipWriter.create(
        tempDir,
        const DataTransferLimits(),
      );
      var e = w.addEntry('metadata.json');
      e.write(Uint8List.fromList(utf8.encode('{"formatVersion": 1}')));
      e.close();

      e = w.addEntry('shots.json');
      final big = utf8.encode(
        '[${List.generate(5000, (i) => '{"id":"s$i","v":"${'x' * 64}"}').join(',')}]',
      );
      for (var i = 0; i < big.length; i += 4096) {
        e.write(
          Uint8List.fromList(big.sublist(i, (i + 4096).clamp(0, big.length))),
        );
      }
      e.close();

      e = w.addEntry('empty.json');
      e.close();
      await w.close();

      final bytes = await w.file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.map((f) => f.name).toList(), [
        'metadata.json',
        'shots.json',
        'empty.json',
      ]);
      expect(jsonDecode(decode(archive.findFile('metadata.json')!.content)), {
        'formatVersion': 1,
      });
      final shots =
          jsonDecode(decode(archive.findFile('shots.json')!.content)) as List;
      expect(shots, hasLength(5000));
      expect(shots.last['id'], 's4999');
      expect(decode(archive.findFile('empty.json')!.content), isEmpty);
    });

    test('compresses large entries (not stored raw)', () async {
      final w = await StreamingZipWriter.create(
        tempDir,
        const DataTransferLimits(),
      );
      final e = w.addEntry('big.json');
      final payload = utf8.encode('a' * 1024 * 1024);
      e.write(payload);
      e.close();
      await w.close();
      final bytes = await w.file.readAsBytes();
      expect(bytes.length, lessThan(payload.length ~/ 10));
    });

    test('abort deletes the temp file', () async {
      final w = await StreamingZipWriter.create(
        tempDir,
        const DataTransferLimits(),
      );
      final e = w.addEntry('a.json');
      e.write(Uint8List.fromList(utf8.encode('{')));
      await w.abort();
      expect(await w.file.exists(), isFalse);
    });

    test('enforces the total uncompressed size limit', () async {
      final w = await StreamingZipWriter.create(
        tempDir,
        const DataTransferLimits(maxTotalUncompressedBytes: 100),
      );
      final e = w.addEntry('a.json');
      e.write(utf8.encode('{"a":"${'x' * 90}"}'));
      e.close();
      final second = w.addEntry('b.json');
      expect(
        () => second.write(utf8.encode('{"b":1}')),
        throwsA(isA<ZipWriteException>()),
      );
      await w.abort();
    });

    test('bounds the completed archive by the import request limit', () async {
      final w = await StreamingZipWriter.create(
        tempDir,
        const DataTransferLimits(maxImportRequestBytes: 500),
      );
      final e = w.addEntry('big.json');
      final random = Random(42);
      e.write(
        Uint8List.fromList(List.generate(600, (_) => random.nextInt(256))),
      );
      e.close();
      await expectLater(w.close(), throwsA(isA<ZipWriteException>()));
      await w.abort();
      expect(await w.file.exists(), isFalse);
    });
  });

  group('StreamingZipReader', () {
    test('reads a legacy in-memory ZIP (no data descriptors)', () async {
      final zipFile = File('${tempDir.path}/legacy.zip');
      await zipFile.writeAsBytes(
        buildLegacyZip({
          'metadata.json': '{"formatVersion":1}',
          'shots.json': '[{"id":"s1"},{"id":"s2"}]',
        }),
      );
      final reader = await StreamingZipReader.open(
        zipFile,
        const DataTransferLimits(),
      );
      expect(reader.entries, hasLength(2));
      final jsonFile = File('${tempDir.path}/shots.json');
      await reader.writeEntryToFile(reader.findEntry('shots.json')!, jsonFile);
      expect(await jsonFile.readAsString(), '[{"id":"s1"},{"id":"s2"}]');
      await reader.close();
    });

    test('round-trips the streaming writer output', () async {
      final w = await StreamingZipWriter.create(
        tempDir,
        const DataTransferLimits(),
      );
      final e = w.addEntry('data.json');
      e.write(Uint8List.fromList(utf8.encode('[1,2,3]')));
      e.close();
      await w.close();

      final reader = await StreamingZipReader.open(
        w.file,
        const DataTransferLimits(),
      );
      final jsonFile = File('${tempDir.path}/data.json');
      await reader.writeEntryToFile(reader.findEntry('data.json')!, jsonFile);
      expect(await jsonFile.readAsString(), '[1,2,3]');
      await reader.close();
    });

    test('rejects a truncated archive', () async {
      final zipFile = File('${tempDir.path}/trunc.zip');
      final bytes = buildLegacyZip({'a.json': '{}'});
      await zipFile.writeAsBytes(bytes.sublist(0, bytes.length - 6));
      await expectLater(
        StreamingZipReader.open(zipFile, const DataTransferLimits()),
        throwsA(isA<ZipReadException>()),
      );
    });

    test('rejects garbage input', () async {
      final zipFile = File('${tempDir.path}/garbage.zip');
      await zipFile.writeAsBytes(List.generate(256, (i) => i % 251));
      await expectLater(
        StreamingZipReader.open(zipFile, const DataTransferLimits()),
        throwsA(isA<ZipReadException>()),
      );
    });

    test('rejects an empty file', () async {
      final zipFile = File('${tempDir.path}/empty.zip');
      await zipFile.writeAsBytes(const []);
      await expectLater(
        StreamingZipReader.open(zipFile, const DataTransferLimits()),
        throwsA(isA<ZipReadException>()),
      );
    });

    test('rejects Zip64 markers', () async {
      final zipFile = File('${tempDir.path}/zip64.zip');
      await zipFile.writeAsBytes(buildLegacyZip({'a.json': '{}'}));
      final bytes = await zipFile.readAsBytes();
      final corrupted = Uint8List.fromList(bytes);
      final eocdPos = bytes.length - 22;
      corrupted[eocdPos + 8] = 0xFF;
      corrupted[eocdPos + 9] = 0xFF;
      await zipFile.writeAsBytes(corrupted);
      await expectLater(
        StreamingZipReader.open(zipFile, const DataTransferLimits()),
        throwsA(
          isA<ZipReadException>().having(
            (e) => e.reason,
            'reason',
            'zip64_unsupported',
          ),
        ),
      );
    });

    test('rejects duplicate entry names', () async {
      final name = 'a.json';
      final nameBytes = utf8.encode(name);
      final content = utf8.encode('{}');
      final local = BytesBuilder(copy: false);
      local.addByte(0x50);
      local.addByte(0x4B);
      local.addByte(0x03);
      local.addByte(0x04);
      _u16(local, 20);
      _u16(local, 0);
      _u16(local, 0);
      _u16(local, 0);
      _u16(local, 0);
      _u32(local, 0);
      _u32(local, 0);
      _u32(local, 0);
      _u16(local, nameBytes.length);
      _u16(local, 0);
      local.add(nameBytes);
      local.add(content);
      Uint8List cdEntry(int localOffset) {
        final b = BytesBuilder(copy: false);
        b.addByte(0x50);
        b.addByte(0x4B);
        b.addByte(0x01);
        b.addByte(0x02);
        _u16(b, 0x031E);
        _u16(b, 20);
        _u16(b, 0);
        _u16(b, 0);
        _u16(b, 0);
        _u16(b, 0);
        _u32(b, 0);
        _u32(b, 0);
        _u32(b, content.length);
        _u16(b, nameBytes.length);
        _u16(b, 0);
        _u16(b, 0);
        _u16(b, 0);
        _u16(b, 0);
        _u32(b, 0);
        _u32(b, localOffset);
        b.add(nameBytes);
        return b.takeBytes();
      }

      final localBytes = local.takeBytes();
      final cd = BytesBuilder(copy: false)
        ..add(cdEntry(0))
        ..add(cdEntry(localBytes.length));
      final cdBytes = cd.takeBytes();
      final eocd = BytesBuilder(copy: false);
      eocd.addByte(0x50);
      eocd.addByte(0x4B);
      eocd.addByte(0x05);
      eocd.addByte(0x06);
      _u16(eocd, 0);
      _u16(eocd, 0);
      _u16(eocd, 2);
      _u16(eocd, 2);
      _u32(eocd, cdBytes.length);
      _u32(eocd, localBytes.length);
      _u16(eocd, 0);

      final zipFile = File('${tempDir.path}/dup.zip');
      await zipFile.writeAsBytes([
        ...localBytes,
        ...cdBytes,
        ...eocd.takeBytes(),
      ]);
      await expectLater(
        StreamingZipReader.open(zipFile, const DataTransferLimits()),
        throwsA(
          isA<ZipReadException>().having(
            (e) => e.reason,
            'reason',
            'duplicate_entry',
          ),
        ),
      );
    });

    test('enforces entry count and uncompressed-size limits', () async {
      final zipFile = File('${tempDir.path}/bomb.zip');
      await zipFile.writeAsBytes(buildLegacyZip({'big.json': 'x' * 1000}));
      await expectLater(
        StreamingZipReader.open(
          zipFile,
          const DataTransferLimits(maxEntryUncompressedBytes: 100),
        ),
        throwsA(
          isA<ZipReadException>().having(
            (e) => e.reason,
            'reason',
            'entry_too_large',
          ),
        ),
      );
    });

    test('rejects oversized total uncompressed size', () async {
      final zipFile = File('${tempDir.path}/total.zip');
      await zipFile.writeAsBytes(buildLegacyZip({'a.json': 'x' * 100}));
      await expectLater(
        StreamingZipReader.open(
          zipFile,
          const DataTransferLimits(maxTotalUncompressedBytes: 50),
        ),
        throwsA(
          isA<ZipReadException>().having(
            (e) => e.reason,
            'reason',
            'total_too_large',
          ),
        ),
      );
    });

    test('rejects CRC mismatch', () async {
      final archive = Archive();
      final file = ArchiveFile.string('a.json', 'hello world');
      file.compression = CompressionType.none;
      archive.addFile(file);
      final zipFile = File('${tempDir.path}/crc.zip');
      await zipFile.writeAsBytes(ZipEncoder().encode(archive));
      final bytes = await zipFile.readAsBytes();
      final corrupted = Uint8List.fromList(bytes);
      corrupted[36] = corrupted[36] ^ 0xFF;
      await zipFile.writeAsBytes(corrupted);
      final reader = await StreamingZipReader.open(
        zipFile,
        const DataTransferLimits(),
      );
      await expectLater(
        reader.writeEntryToFile(
          reader.findEntry('a.json')!,
          File('${tempDir.path}/a.json'),
        ),
        throwsA(
          isA<ZipReadException>().having(
            (e) => e.reason,
            'reason',
            'crc_mismatch',
          ),
        ),
      );
      await reader.close();
    });
  });
}

void _u16(BytesBuilder b, int value) {
  b.addByte(value & 0xFF);
  b.addByte((value >> 8) & 0xFF);
}

void _u32(BytesBuilder b, int value) {
  b.addByte(value & 0xFF);
  b.addByte((value >> 8) & 0xFF);
  b.addByte((value >> 16) & 0xFF);
  b.addByte((value >> 24) & 0xFF);
}
