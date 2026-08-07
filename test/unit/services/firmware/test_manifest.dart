const testManifestJson = '''
{
  "schemaVersion": 1,
  "artifacts": [
    {
      "id": "de1-1356",
      "source": "bundled",
      "machineFamily": "de1",
      "supportedModels": ["DE1Pro", "DE1XL", "DE1XXL", "DE1XXXL"],
      "build": 1356,
      "versionLabel": "1356",
      "imageFormat": "de1",
      "byteLength": 200,
      "sha256": "__REPLACE_ME__",
      "channel": "stable",
      "releaseNotes": "First bundled DE1 firmware.",
      "assetPath": "assets/firmware/de1/de1-1356.bin",
      "expectedHeaderBoardMarker": 3725590529,
      "expectedBodyByteCount": 100000,
      "expectedCpuByteCount": 20000,
      "provenance": "Placeholder — replace with real build reference."
    }
  ]
}
''';
