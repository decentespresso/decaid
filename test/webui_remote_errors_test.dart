import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/util/remote_update_exception.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import 'helpers/mock_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late WebUIStorage storage;
  const manifestAsset = 'assets/bundled_skins/manifest.json';
  const sourcesAsset = 'skin_sources.json';

  setUp(() {
    directory = Directory.systemTemp.createTempSync('decaid_remote_skins');
    storage = WebUIStorage(
      SettingsController(MockSettingsService()),
      webUIDir: directory,
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile.string('index.html', '<title>Offline fixture</title>'),
      )
      ..addFile(
        ArchiveFile.string(
          'skin-manifest.json',
          jsonEncode({'id': 'offline-fixture', 'name': 'Offline fixture'}),
        ),
      );
    final assets = {
      manifestAsset: Uint8List.fromList(
        utf8.encode(jsonEncode(['offline-fixture'])),
      ),
      'assets/bundled_skins/offline-fixture.zip': Uint8List.fromList(
        ZipEncoder().encode(archive),
      ),
      sourcesAsset: Uint8List.fromList(
        utf8.encode(
          jsonEncode([
            {'type': 'github_release', 'repo': 'fixture/first'},
            {'type': 'github_release', 'repo': 'fixture/second'},
          ]),
        ),
      ),
    };
    rootBundle.evict(manifestAsset);
    rootBundle.evict(sourcesAsset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final bytes = assets[const StringCodec().decodeMessage(message)];
          return bytes == null ? null : ByteData.sublistView(bytes);
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    rootBundle.evict(manifestAsset);
    rootBundle.evict(sourcesAsset);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    directory.deleteSync(recursive: true);
  });

  test('offline initialization retains bundled skins', () async {
    await http.runWithClient(
      () => storage.initialize(),
      () => MockClient((_) async => throw const SocketException('offline')),
    );
    expect(storage.installedSkins.map((skin) => skin.id), ['offline-fixture']);
    expect(storage.defaultSkin?.id, 'offline-fixture');
    expect(
      await File('${directory.path}/offline-fixture/index.html').readAsString(),
      '<title>Offline fixture</title>',
    );
  });

  test('remote downloads share failures and allow a later retry', () async {
    await storage.initialize(downloadRemote: false);
    final release = Completer<void>();
    var requests = 0;
    await http.runWithClient(
      () async {
        final first = storage.downloadRemoteSkins();
        final second = storage.downloadRemoteSkins();
        try {
          expect(second, same(first));
        } finally {
          release.complete();
          await Future.wait([
            expectLater(first, throwsA(isA<RemoteUpdateException>())),
            expectLater(second, throwsA(isA<RemoteUpdateException>())),
          ]);
        }
        final firstBatchRequests = requests;
        await expectLater(
          storage.downloadRemoteSkins(),
          throwsA(isA<RemoteUpdateException>()),
        );
        expect(requests, firstBatchRequests * 2);
      },
      () => MockClient((_) async {
        requests++;
        await release.future;
        throw const SocketException('offline');
      }),
    );
  });

  test(
    'offline update attempts every remote source and retains installed skins',
    () async {
      await storage.initialize(downloadRemote: false);
      final installed = storage.installedSkins.map((skin) => skin.id).toList();
      var requests = 0;
      await expectLater(
        http.runWithClient(
          storage.updateAllSkins,
          () => MockClient((_) async {
            requests++;
            throw const SocketException('offline');
          }),
        ),
        throwsA(
          isA<RemoteUpdateException>()
              .having(
                (error) => error.failures.length,
                'failures',
                greaterThan(1),
              )
              .having((error) => error.isPartial, 'isPartial', isFalse),
        ),
      );
      expect(requests, greaterThan(1));
      expect(
        storage.installedSkins.map((skin) => skin.id),
        unorderedEquals(installed),
      );
      expect(storage.updateCheck.value, isNull);
    },
  );
}
