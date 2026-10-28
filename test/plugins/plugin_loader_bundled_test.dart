import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'time-to-ready.reaplugin';
  const manifestAsset = 'assets/plugins/$id/manifest.json';
  const scriptAsset = 'assets/plugins/$id/plugin.js';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tempDir;
  late PluginLoaderService service;
  late Map<String, String> assets;
  late StreamSubscription<LogRecord> logSubscription;
  late List<LogRecord> warnings;
  const otherId = 'visualizer.reaplugin';
  const otherManifestAsset = 'assets/plugins/$otherId/manifest.json';
  const otherScriptAsset = 'assets/plugins/$otherId/plugin.js';

  String manifest(String? version, String name) => jsonEncode({
    'id': id,
    'author': 'Test',
    'name': name,
    'description': 'Bundled copy regression fixture',
    'version': ?version,
    'apiVersion': 1,
    'permissions': <String>[],
    'settings': <String, dynamic>{},
    'api': <Object>[],
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('plugin_loader_bundled');
    service = PluginLoaderService(kvStore: FakeKeyValueStoreService());
    assets = {};
    warnings = [];
    logSubscription = Logger('PluginLoaderService').onRecord.listen((record) {
      if (record.level >= Level.WARNING) warnings.add(record);
    });
    rootBundle.evict(otherManifestAsset);
    rootBundle.evict(otherScriptAsset);
    rootBundle.evict(manifestAsset);
    rootBundle.evict(scriptAsset);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tempDir.path,
    );
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final asset = assets[const StringCodec().decodeMessage(message)];
      return asset == null
          ? null
          : ByteData.sublistView(Uint8List.fromList(utf8.encode(asset)));
    });
  });

  tearDown(() async {
    await service.dispose();
    await logSubscription.cancel();
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    messenger.setMockMessageHandler('flutter/assets', null);
    rootBundle.evict(manifestAsset);
    rootBundle.evict(scriptAsset);
    rootBundle.evict(otherManifestAsset);
    rootBundle.evict(otherScriptAsset);
    tempDir.deleteSync(recursive: true);
  });

  group('startup bundled plugin version policy', () {
    for (final scenario
        in <({String name, String? installed, String? bundled, bool replace})>[
          (name: 'equal', installed: '1.0.0', bundled: '1.0.0', replace: false),
          (
            name: 'installed newer',
            installed: '2.0.0',
            bundled: '1.0.0',
            replace: false,
          ),
          (
            name: 'installed older',
            installed: '0.9.0',
            bundled: '1.0.0',
            replace: true,
          ),
          (
            name: 'installed prerelease',
            installed: '0.12.1-dev.2',
            bundled: '0.12.1',
            replace: true,
          ),
          (
            name: 'bundled prerelease',
            installed: '0.12.1',
            bundled: '0.12.1-dev.2',
            replace: false,
          ),
          (
            name: 'build metadata only',
            installed: '1.0.0+build.1',
            bundled: '1.0.0+build.2',
            replace: false,
          ),
          for (final version in <String?>['', 'dist', '1.x.0', null]) ...[
            (
              name: 'invalid installed $version',
              installed: version,
              bundled: '2.0.0',
              replace: false,
            ),
            (
              name: 'invalid bundled $version',
              installed: '0.0.1',
              bundled: version,
              replace: false,
            ),
          ],
        ]) {
      test('${scenario.name}: preserves or replaces both file bytes', () async {
        assets[manifestAsset] = manifest(scenario.bundled, 'Bundled');
        assets[scriptAsset] = '// bundled script\n';
        final directory = Directory('${tempDir.path}/plugins/$id')
          ..createSync(recursive: true);
        final manifestFile = File('${directory.path}/manifest.json')
          ..writeAsStringSync('${manifest(scenario.installed, 'Installed')}\n');
        final scriptFile = File('${directory.path}/plugin.js')
          ..writeAsStringSync('// locally installed script\n');
        final originalManifest = manifestFile.readAsBytesSync();
        final originalScript = scriptFile.readAsBytesSync();

        await service.initialize();

        expect(
          manifestFile.readAsBytesSync(),
          scenario.replace
              ? utf8.encode(assets[manifestAsset]!)
              : originalManifest,
        );
        expect(
          scriptFile.readAsBytesSync(),
          scenario.replace ? utf8.encode(assets[scriptAsset]!) : originalScript,
        );
      });
    }
  });

  for (final damage in [
    'missing manifest',
    'malformed manifest',
    'missing script',
  ]) {
    test(
      'damaged installation: $damage preserves files and continues',
      () async {
        assets[manifestAsset] = manifest('2.0.0', 'Bundled');
        assets[scriptAsset] = '// bundled script\n';
        assets[otherManifestAsset] = jsonEncode({
          ...jsonDecode(manifest('1.0.0', 'Other')) as Map<String, dynamic>,
          'id': otherId,
        });
        assets[otherScriptAsset] = '// other bundled script\n';
        final directory = Directory('${tempDir.path}/plugins/$id')
          ..createSync(recursive: true);
        if (damage != 'missing manifest') {
          File('${directory.path}/manifest.json').writeAsStringSync(
            damage == 'malformed manifest'
                ? '{broken json'
                : manifest('1.0.0', 'Installed'),
          );
        }
        if (damage != 'missing script') {
          File(
            '${directory.path}/plugin.js',
          ).writeAsStringSync('// locally installed script\n');
        }
        final originalFiles = {
          for (final file in directory.listSync().whereType<File>())
            file.path: file.readAsBytesSync(),
        };

        await expectLater(service.initialize(), completes);

        expect(
          directory.listSync().map((file) => file.path),
          unorderedEquals(originalFiles.keys),
        );
        for (final entry in originalFiles.entries) {
          expect(File(entry.key).readAsBytesSync(), entry.value);
        }
        expect(
          File(
            '${tempDir.path}/plugins/$otherId/manifest.json',
          ).readAsBytesSync(),
          utf8.encode(assets[otherManifestAsset]!),
        );
        expect(
          File('${tempDir.path}/plugins/$otherId/plugin.js').readAsBytesSync(),
          utf8.encode(assets[otherScriptAsset]!),
        );
        expect(
          warnings.any(
            (record) =>
                record.message.contains(id) &&
                record.message.contains(
                  'manual reinstallation may be required',
                ),
          ),
          isTrue,
        );
      },
    );
  }

  for (final emptyDirectory in [false, true]) {
    test(
      'fresh install with empty directory $emptyDirectory copies bundle',
      () async {
        assets[manifestAsset] = manifest('1.0.0', 'Bundled');
        assets[scriptAsset] = '// bundled script\n';
        final directory = Directory('${tempDir.path}/plugins/$id');
        if (emptyDirectory) directory.createSync(recursive: true);

        await service.initialize();

        expect(
          File('${directory.path}/manifest.json').readAsBytesSync(),
          utf8.encode(assets[manifestAsset]!),
        );
        expect(
          File('${directory.path}/plugin.js').readAsBytesSync(),
          utf8.encode(assets[scriptAsset]!),
        );
        expect(service.getPluginManifest(id)?.version, '1.0.0');
      },
    );
  }
}
