import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import 'helpers/mock_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebUIStorage safe skin ids', () {
    late Directory tmpRoot;
    late Directory webUIDir;
    late WebUIStorage storage;
    var sourceCounter = 0;

    setUp(() async {
      tmpRoot = Directory.systemTemp.createTempSync('webui_safe_ids_test');
      webUIDir = Directory('${tmpRoot.path}/web-ui');

      final settingsController = SettingsController(MockSettingsService());
      await settingsController.loadSettings();
      storage = WebUIStorage(settingsController);
      storage.debugInitWithWebUIDir(webUIDir);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tmpRoot.path,
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
    });

    Directory makeSource(String id) {
      final dir = Directory('${tmpRoot.path}/src_${sourceCounter++}')
        ..createSync();
      File('${dir.path}/skin-manifest.json').writeAsStringSync(
        jsonEncode({'id': id, 'name': 'Test Skin', 'version': '1.0.0'}),
      );
      File('${dir.path}/index.html').writeAsStringSync('<html></html>');
      return dir;
    }

    const unsafeIds = [
      '',
      '.',
      '..',
      '../escape',
      'a/b',
      r'a\b',
      '/abs',
      r'\abs',
      'C:evil',
      r'\\server\share',
      'a?b',
      'trailing.',
      'trailing ',
    ];

    for (final id in unsafeIds) {
      test('rejects skin id ${id.isEmpty ? '(empty)' : '"$id"'}', () async {
        final source = makeSource(id);

        await expectLater(
          storage.installFromPath(source.path),
          throwsFormatException,
        );

        expect(
          webUIDir.listSync().whereType<Directory>(),
          isEmpty,
          reason: 'no skin directory may be created for unsafe id "$id"',
        );
        expect(storage.installedSkins, isEmpty);
      });
    }

    test('valid ids with dots, hyphens and underscores install fine', () async {
      for (final id in ['streamline.js', 'my-skin_v2.3', 'passione-dist']) {
        final source = makeSource(id);

        final installedId = await storage.installFromPath(source.path);

        expect(installedId, id);
        expect(Directory('${webUIDir.path}/$id').existsSync(), isTrue);
        expect(storage.getSkin(id), isNotNull);
      }
    });

    test(
      'unsafe manifest ids cannot enter the in-memory registry on scan',
      () async {
        final goodSource = makeSource('good.skin');
        await storage.installFromPath(goodSource.path);
        expect(storage.getSkin('good.skin'), isNotNull);

        final evilDir = Directory('${webUIDir.path}/evil-dir')..createSync();
        File(
          '${evilDir.path}/skin-manifest.json',
        ).writeAsStringSync(jsonEncode({'id': '../escape', 'name': 'Evil'}));
        File('${evilDir.path}/index.html').writeAsStringSync('<html></html>');

        final anotherSource = makeSource('another.skin');
        await storage.installFromPath(anotherSource.path);

        expect(storage.getSkin('../escape'), isNull);
        expect(
          storage.installedSkins.any((s) => s.id == '../escape'),
          isFalse,
          reason: 'an unsafe manifest id must not enter the registry',
        );
        expect(storage.getSkin('good.skin'), isNotNull);
        expect(storage.getSkin('another.skin'), isNotNull);
      },
    );
  });
}
