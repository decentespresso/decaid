import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/export/streaming_zip_writer.dart';

void main() {
  Future<Directory> createDir() async {
    final dir = await Directory.systemTemp.createTemp('streaming-zip-');
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  test('writeFile round-trips a file exact bytes', () async {
    final dir = await createDir();
    final source = File('${dir.path}/source.bin');
    final bytes = Uint8List.fromList(
      List.generate(3 * 1024 * 1024, (i) => i % 251),
    );
    await source.writeAsBytes(bytes);
    final writer = await StreamingZipWriter.create(
      destination: File('${dir.path}/archive.zip'),
    );
    await writer.writeFile(source, 'source.bin');
    await writer.close();
    final archive = ZipDecoder().decodeBytes(await writer.file.readAsBytes());
    expect(archive.findFile('source.bin')!.content, bytes);
  });

  test('compression level changes the compressed size', () async {
    final dir = await createDir();
    final payload = Uint8List.fromList(List.filled(200000, 97));
    final sizes = <int, int>{};

    for (final level in [0, 6]) {
      final path = '${dir.path}/level-$level.zip';
      final writer = await StreamingZipWriter.create(
        destination: File(path),
        compressionLevel: level,
      );
      final entry = writer.addEntry('payload.bin');
      entry.write(payload);
      entry.close();
      await writer.close();

      sizes[level] = File(path).lengthSync();
      final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
      expect(archive.findFile('payload.bin')!.content, payload);
    }

    expect(sizes[0], greaterThan(sizes[6]!));
  });

  test('null maxFilenameBytes accepts a long entry name', () async {
    final dir = await createDir();
    final name = 'x' * 1024;
    final writer = await StreamingZipWriter.create(
      destination: File('${dir.path}/archive.zip'),
      maxFilenameBytes: null,
    );
    final entry = writer.addEntry(name);
    entry.close();
    await writer.close();
  });

  test('maxFilenameBytes rejects a long entry name', () async {
    final dir = await createDir();
    final writer = await StreamingZipWriter.create(
      destination: File('${dir.path}/archive.zip'),
      maxFilenameBytes: 10,
    );

    expect(
      () => writer.addEntry('this-entry-name-is-too-long'),
      throwsA(isA<ZipWriteException>()),
    );
    await writer.abort();
  });

  test('null maxEntryCount accepts more than 4096 entries', () async {
    final dir = await createDir();
    final writer = await StreamingZipWriter.create(
      destination: File('${dir.path}/archive.zip'),
      maxEntryCount: null,
    );
    for (var i = 0; i < 4097; i++) {
      final entry = writer.addEntry('entry-$i');
      entry.close();
    }
    await writer.close();
  });

  test('rejects a name beyond the ZIP16 length field', () async {
    final dir = await createDir();
    final writer = await StreamingZipWriter.create(
      destination: File('${dir.path}/archive.zip'),
    );

    expect(
      () => writer.addEntry('x' * 0x10000),
      throwsA(isA<ZipWriteException>()),
    );
    await writer.abort();
  });

  test(
    'rejects more than the ZIP16 entry count without configured limits',
    () async {
      final dir = await createDir();
      final writer = await StreamingZipWriter.create(
        destination: File('${dir.path}/archive.zip'),
        maxEntryCount: null,
      );
      for (var i = 0; i < 0xFFFF; i++) {
        writer.addEntry('e$i').close();
      }

      expect(
        () => writer.addEntry('overflow'),
        throwsA(isA<ZipWriteException>()),
      );
      await writer.abort();
    },
  );

  test('accepts a name at the ZIP16 length boundary', () async {
    final dir = await createDir();
    final writer = await StreamingZipWriter.create(
      destination: File('${dir.path}/archive.zip'),
    );
    final entry = writer.addEntry('x' * 0xFFFF);
    entry.write(Uint8List.fromList([1]));
    entry.close();
    await writer.close();

    final archive = ZipDecoder().decodeBytes(await writer.file.readAsBytes());
    expect(archive.files.single.name.length, 0xFFFF);
  });
}
