import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/export/archive_export.dart';

void main() {
  test('zipFiles round-trips multiple entries', () {
    final files = {
      'one.txt': Uint8List.fromList([1, 2, 3]),
      'two.bin': Uint8List.fromList([4, 5, 6, 7]),
    };
    final archive = ZipDecoder().decodeBytes(zipFiles(files));

    expect(archive.files.map((file) => file.name), files.keys);
    for (final entry in files.entries) {
      expect(archive.findFile(entry.key)!.content, entry.value);
    }
  });

  test('zipFiles round-trips an empty map', () {
    final archive = ZipDecoder().decodeBytes(zipFiles({}));

    expect(archive.files, isEmpty);
  });
}
