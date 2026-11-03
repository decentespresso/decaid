import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/firmware/firmware_manifest.dart';

void main() {
  group('FirmwareManifest', () {
    test('parses a valid manifest with one artifact', () {
      final json = {
        'schemaVersion': 1,
        'artifacts': [
          {
            'id': 'de1-1356',
            'source': 'bundled',
            'machineFamily': 'de1',
            'supportedModels': ['DE1', 'DE1Plus', 'DE1Cafe', 'DE1Pro', 'DE1XL'],
            'build': 1356,
            'versionLabel': '1356',
            'imageFormat': 'de1',
            'byteLength': 123456,
            'sha256':
                'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            'channel': 'stable',
            'releaseNotes': 'Initial bundled firmware.',
            'assetPath': 'assets/firmware/de1/de1-1356.bin',
            'expectedHeaderBoardMarker': 0xDE100001,
            'expectedBodyByteCount': 100000,
            'expectedCpuByteCount': 20000,
            'provenance': 'Built from de1app repo tag v1.42',
          },
        ],
      };
      final manifest = FirmwareManifest.parse(jsonEncode(json));

      expect(manifest.schemaVersion, 1);
      expect(manifest.entries, hasLength(1));
      expect(manifest.entries[0].artifact.id, 'de1-1356');
      expect(manifest.entries[0].artifact.build, 1356);
      expect(manifest.entries[0].assetPath, 'assets/firmware/de1/de1-1356.bin');
      expect(manifest.entries[0].expectedHeaderBoardMarker, 0xDE100001);
      expect(
        manifest.entries[0].provenance,
        'Built from de1app repo tag v1.42',
      );
    });

    test('rejects unsupported schema version', () {
      for (final version in [0, 2]) {
        final json = {'schemaVersion': version, 'artifacts': []};
        expect(
          () => FirmwareManifest.parse(jsonEncode(json)),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('rejects duplicate artifact IDs', () {
      final json = {
        'schemaVersion': 1,
        'artifacts': [
          _validEntryJson(id: 'de1-1356'),
          _validEntryJson(id: 'de1-1356'),
        ],
      };
      expect(
        () => FirmwareManifest.parse(jsonEncode(json)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects manifest entry with empty supported models', () {
      final entry = _validEntryJson();
      (entry as Map)['supportedModels'] = <String>[];
      final json = {
        'schemaVersion': 1,
        'artifacts': [entry],
      };
      expect(
        () => FirmwareManifest.parse(jsonEncode(json)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects manifest entry with malformed SHA-256', () {
      for (final digest in ['too-short', List.filled(64, 'z').join()]) {
        final entry = _validEntryJson()..['sha256'] = digest;
        final json = {
          'schemaVersion': 1,
          'artifacts': [entry],
        };
        expect(
          () => FirmwareManifest.parse(jsonEncode(json)),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('accepts canonical DE1-family model names', () {
      final entry = _validEntryJson()
        ..['supportedModels'] = ['DE1', 'DE1Plus', 'DE1Cafe'];
      final manifest = FirmwareManifest.parse(
        jsonEncode({
          'schemaVersion': 1,
          'artifacts': [entry],
        }),
      );

      expect(manifest.entries.single.artifact.supportedModels, {
        'DE1',
        'DE1Plus',
        'DE1Cafe',
      });
    });

    test('rejects unknown machine families and models', () {
      final unknownFamily = _validEntryJson()..['machineFamily'] = 'bengle';
      final unknownModel = _validEntryJson()..['supportedModels'] = ['DE1CAFE'];
      for (final entry in [unknownFamily, unknownModel]) {
        expect(
          () => FirmwareManifest.parse(
            jsonEncode({
              'schemaVersion': 1,
              'artifacts': [entry],
            }),
          ),
          throwsA(isA<FormatException>()),
        );
      }
    });
  });
}

Map<String, dynamic> _validEntryJson({String id = 'de1-1356'}) {
  return {
    'id': id,
    'source': 'bundled',
    'machineFamily': 'de1',
    'supportedModels': ['DE1Pro'],
    'build': 1356,
    'versionLabel': '1356',
    'imageFormat': 'de1',
    'byteLength': 123456,
    'sha256':
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'channel': 'stable',
    'releaseNotes': 'Test release.',
    'assetPath': 'assets/firmware/de1/$id.bin',
    'expectedHeaderBoardMarker': 0xDE100001,
    'expectedBodyByteCount': 100000,
    'expectedCpuByteCount': 20000,
    'provenance': 'Test build.',
  };
}
