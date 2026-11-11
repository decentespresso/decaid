import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PluginLoaderService loader;
  late PluginSourceService service;

  const id = 'manager.reaplugin';
  final manageExtensions = PluginPermissions.manageExtensions.wireName;

  Map<String, dynamic> manifestJson({
    String version = '1.0.0',
    List<String> permissions = const [],
  }) => {
    'id': id,
    'author': 'Test',
    'name': 'Manager plugin',
    'description': 'Test plugin',
    'version': version,
    'apiVersion': 1,
    'permissions': permissions,
    'settings': <String, dynamic>{},
    'api': <Object>[],
  };

  const pluginJs =
      '''
function createPlugin() {
  return { id: "$id", onLoad() {} };
}
''';

  var folderCount = 0;
  String pluginFolder({
    String version = '1.0.0',
    List<String> permissions = const [],
  }) {
    final dir = Directory('${tempDir.path}/candidates/${folderCount++}/$id')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json').writeAsStringSync(
      jsonEncode(manifestJson(version: version, permissions: permissions)),
    );
    File('${dir.path}/plugin.js').writeAsStringSync(pluginJs);
    return dir.path;
  }

  String pluginZip({
    String version = '1.0.0',
    List<String> permissions = const [],
  }) {
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'wrapper/manifest.json',
          jsonEncode(manifestJson(version: version, permissions: permissions)),
        ),
      )
      ..addFile(ArchiveFile.string('wrapper/plugin.js', pluginJs));
    final file = File('${tempDir.path}/candidate-${folderCount++}.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    return file.path;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('plugin_extension_approval');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempDir.path,
        );
    loader = PluginLoaderService(kvStore: FakeKeyValueStoreService());
    await loader.initialize();
    for (final plugin in loader.availablePlugins) {
      await loader.removePlugin(plugin.id);
    }
    service = PluginSourceService(loader);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await loader.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'a candidate requesting manage.extensions is shown to the approver once',
    () async {
      final asked = <PluginManifest>[];

      await service.installFromFolder(
        pluginFolder(permissions: [manageExtensions]),
        approveExtensionManagement: (candidate) async {
          asked.add(candidate);
          return true;
        },
      );

      expect(asked, hasLength(1));
      expect(asked.single.id, id);
      expect(asked.single.version, '1.0.0');
      expect(
        asked.single.permissions,
        contains(PluginPermissions.manageExtensions),
      );
    },
  );

  test('a declined folder install installs nothing', () async {
    await expectLater(
      service.installFromFolder(
        pluginFolder(permissions: [manageExtensions]),
        approveExtensionManagement: (_) async => false,
      ),
      throwsA(
        isA<PluginInstallDeclinedException>().having(
          (e) => e.pluginId,
          'pluginId',
          id,
        ),
      ),
    );

    expect(loader.getPluginManifest(id), isNull);
    expect(service.sourceFor(id), isNull);
    expect(Directory('${tempDir.path}/plugins/$id').existsSync(), isFalse);
  });

  test('a declined zip install installs nothing', () async {
    await expectLater(
      service.installFromZip(
        pluginZip(permissions: [manageExtensions]),
        approveExtensionManagement: (_) async => false,
      ),
      throwsA(isA<PluginInstallDeclinedException>()),
    );

    expect(loader.getPluginManifest(id), isNull);
    expect(service.sourceFor(id), isNull);
  });

  test(
    'a declined update leaves the installed version in place and loaded',
    () async {
      await service.installFromFolder(pluginFolder(version: '1.0.0'));
      final installedSource = service.sourceFor(id)!;
      await loader.enablePlugin(id);
      expect(loader.isPluginLoaded(id), isTrue);

      await expectLater(
        service.installFromZip(
          pluginZip(version: '1.1.0', permissions: [manageExtensions]),
          approveExtensionManagement: (_) async => false,
        ),
        throwsA(isA<PluginInstallDeclinedException>()),
      );

      final installed = loader.getPluginManifest(id)!;
      expect(installed.version, '1.0.0');
      expect(
        installed.permissions,
        isNot(contains(PluginPermissions.manageExtensions)),
      );
      expect(loader.isPluginLoaded(id), isTrue);
      final source = service.sourceFor(id)!;
      expect(source.kind, PluginSourceKind.localFolder);
      expect(source.installedAt, installedSource.installedAt);
      final onDisk =
          jsonDecode(
                File(
                  '${loader.getPluginDirectory(id)}/manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(onDisk['version'], '1.0.0');
    },
  );

  test('an approved install installs the candidate', () async {
    final manifest = await service.installFromZip(
      pluginZip(permissions: [manageExtensions]),
      approveExtensionManagement: (_) async => true,
    );

    expect(manifest.id, id);
    final installed = loader.getPluginManifest(id)!;
    expect(installed.permissions, contains(PluginPermissions.manageExtensions));
    expect(service.sourceFor(id)!.kind, PluginSourceKind.localZip);
    expect(Directory('${tempDir.path}/plugins/$id').existsSync(), isTrue);
  });

  test(
    'the approver is not asked for a candidate without manage.extensions',
    () async {
      var asked = 0;

      await service.installFromFolder(
        pluginFolder(permissions: [PluginPermissions.log.wireName]),
        approveExtensionManagement: (_) async {
          asked++;
          return false;
        },
      );

      expect(asked, 0);
      expect(loader.getPluginManifest(id)?.version, '1.0.0');
    },
  );

  test(
    'the approver is not asked when the installed version already holds it',
    () async {
      await service.installFromFolder(
        pluginFolder(permissions: [manageExtensions]),
        approveExtensionManagement: (_) async => true,
      );
      var asked = 0;

      await service.installFromZip(
        pluginZip(version: '1.1.0', permissions: [manageExtensions]),
        approveExtensionManagement: (_) async {
          asked++;
          return false;
        },
      );

      expect(asked, 0);
      expect(loader.getPluginManifest(id)?.version, '1.1.0');
    },
  );

  test('without an approver the install proceeds', () async {
    await service.installFromFolder(
      pluginFolder(permissions: [manageExtensions]),
    );

    expect(
      loader.getPluginManifest(id)?.permissions,
      contains(PluginPermissions.manageExtensions),
    );
  });
}
